import asyncio
import json
from pathlib import Path
import sys
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from core import Store, validate_request, verdict


class CloudRulesTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.store = Store(lambda: self.now)
        self.sid = str(uuid.uuid4())
        self.sample = dict(latitude=37, longitude=-122, confirmedAt=980.0)
        self.data = dict(version=1, sessionID=self.sid, startedAt=970.0, sentAt=1000.0,
                         sequence=1, active=True, samples=[self.sample])
        self.report = dict(provider="findmy-device", target="Test iPhone", state="ok",
                           latitude=37.0, longitude=-122.0, locatedAt=995.0, accuracy=5.0, fetchedAt=1000.0)

    def test_fresh_apple_match(self):
        self.store.update(self.data)
        self.store.publish(self.sid, self.report)
        self.assertEqual(self.store.snapshot()["status"], "match")

    def test_actual_difference(self):
        self.report["latitude"] = 38
        self.assertEqual(verdict(self.report, [self.sample], self.now, True), "different")

    def test_route_compares_time_not_latest_point(self):
        samples = [dict(self.sample, validUntil=996), dict(latitude=38, longitude=-122, confirmedAt=997)]
        self.assertEqual(verdict(self.report, samples, self.now, True), "match")

    def test_write_gap_is_unknown(self):
        self.assertEqual(verdict(self.report, [dict(self.sample, validUntil=994)], self.now, True), "waiting")

    def test_old_fix_cannot_be_refreshed_by_download(self):
        self.report["locatedAt"] = 800
        self.assertEqual(verdict(self.report, [self.sample], self.now, True), "old")

    def test_provider_old_flag_wins(self):
        self.report["state"] = "old"
        self.assertEqual(verdict(self.report, [self.sample], self.now, True), "old")

    def test_missing_accuracy_does_not_match(self):
        self.report["accuracy"] = None
        self.assertEqual(verdict(self.report, [self.sample], self.now, True), "unavailable")

    def test_force_closed_client_expires_and_forgets_coordinates(self):
        self.store.update(self.data)
        self.store.publish(self.sid, self.report)
        self.now += 151
        self.assertIsNone(self.store.polling_id())
        self.assertIsNone(self.store.snapshot()["report"])
        self.assertEqual(self.store.session.history, [])

    def test_late_fetch_after_stop_cannot_restore_report(self):
        self.store.update(self.data)
        self.store.close(self.sid)
        self.store.publish(self.sid, self.report)
        self.assertIsNone(self.store.snapshot()["report"])
        self.assertEqual(self.store.snapshot()["status"], "paused")

    def test_inflight_post_after_stop_rejected(self):
        self.store.update(self.data)
        self.store.close(self.sid)
        with self.assertRaises(RuntimeError):
            self.store.update(dict(self.data, sequence=2))

    def test_stop_arrives_before_first_post(self):
        self.store.close(self.sid)
        with self.assertRaises(RuntimeError): self.store.update(self.data)
        self.assertIsNone(self.store.polling_id())

    def test_old_session_and_sequence_rejected(self):
        self.store.update(self.data)
        with self.assertRaises(RuntimeError): self.store.update(self.data)
        other = dict(self.data, sessionID=str(uuid.uuid4()), startedAt=979)
        self.store.update(other)
        with self.assertRaises(RuntimeError): self.store.update(dict(self.data, sequence=2))
        self.store.close(self.sid)
        self.assertEqual(self.store.polling_id(), other["sessionID"])

    def test_new_session_does_not_inherit_old_report(self):
        self.store.update(self.data)
        self.store.publish(self.sid, self.report)
        new = dict(self.data, sessionID=str(uuid.uuid4()), startedAt=979)
        self.assertIsNone(self.store.update(new)["report"])
        self.store.publish(self.sid, self.report)
        self.assertIsNone(self.store.snapshot()["report"])

    def test_pausing_forgets_points_and_does_not_poll(self):
        self.store.update(self.data)
        self.store.update(dict(self.data, sequence=2, active=False, samples=[]))
        self.assertIsNone(self.store.polling_id())
        self.assertEqual(self.store.session.history, [])

    def test_signout_stops_apple_requests_and_survives_new_session(self):
        self.store.update(self.data)
        self.store.publish(self.sid, dict(self.report, state="sign-in"))
        self.assertIsNone(self.store.polling_id())
        self.assertEqual(self.store.snapshot()["status"], "sign-in")
        self.store.update(dict(self.data, sessionID=str(uuid.uuid4()), startedAt=979))
        self.assertEqual(self.store.snapshot()["status"], "sign-in")

    def test_bad_data_and_clock_rejected(self):
        for changes in [dict(sentAt=950), dict(sequence=True), dict(sequence=0), dict(active="yes"),
                        dict(samples=[dict(self.sample, latitude=float("nan"))]),
                        dict(samples=[dict(self.sample, latitude=91)]),
                        dict(samples=[dict(self.sample, confirmedAt=960)]),
                        dict(samples=[dict(self.sample, validUntil=979)]), dict(samples=[self.sample]*2001)]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_request(dict(self.data, **changes), self.now)

    def test_missing_interval_and_overlap_rejected(self):
        for samples in [[self.sample, dict(self.sample, confirmedAt=990)],
                        [dict(self.sample, validUntil=991), dict(self.sample, confirmedAt=990)]]:
            with self.assertRaises(ValueError):
                validate_request(dict(self.data, samples=samples), self.now)


class CloudHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from aiohttp.test_utils import TestClient, TestServer
        from server import make_app
        self.store = Store()
        self.calls = 0
        outer = self
        class FakeConnector:
            def fetch(self):
                outer.calls += 1
                from reports import missing
                return missing("findmy-device", "Test iPhone", "sign-in")
        self.client = TestClient(TestServer(make_app("a"*64, FakeConnector(), self.store, interval=1)))
        await self.client.start_server()
        self.headers = {"Authorization": "Bearer " + "a"*64}

    async def asyncTearDown(self):
        await self.client.close()

    async def test_auth_required_and_no_account_control_endpoint(self):
        response = await self.client.post("/v1/check", json={})
        self.assertEqual(response.status, 401)
        for path in ("/", "/erase", "/login", "/play_sound"):
            response = await self.client.get(path, headers=self.headers)
            self.assertEqual(response.status, 404)
        self.assertEqual(self.calls, 0)

    async def test_check_start_auth_failure_and_delete(self):
        import time
        sid = str(uuid.uuid4())
        now = time.time()
        payload = dict(version=1, sessionID=sid, startedAt=now, sentAt=now, sequence=1, active=True, samples=[])
        response = await self.client.post("/v1/check", json=payload, headers=self.headers)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        await asyncio.sleep(1.2)
        self.assertEqual(self.store.snapshot()["status"], "sign-in")
        self.assertEqual(self.calls, 1)
        response = await self.client.delete("/v1/session/"+sid, headers=self.headers)
        self.assertEqual(response.status, 204)
        self.assertEqual(self.store.snapshot()["status"], "paused")

    async def test_malformed_and_large_requests_rejected(self):
        response = await self.client.post("/v1/check", data="{broken", headers=self.headers)
        self.assertEqual(response.status, 400)
        await asyncio.sleep(1.05)
        response = await self.client.post("/v1/check", data="x"*(513*1024), headers=self.headers)
        self.assertEqual(response.status, 413)

    async def test_fast_repeated_requests_rate_limited(self):
        await self.client.post("/v1/check", json={}, headers=self.headers)
        response = await self.client.post("/v1/check", json={}, headers=self.headers)
        self.assertEqual(response.status, 429)


class CloudTLSTests(unittest.IsolatedAsyncioTestCase):
    async def test_pinned_tls_pairing_and_wrong_certificate_rejected(self):
        import tempfile
        import ssl
        import aiohttp
        from aiohttp.test_utils import TestServer
        from server import initialize, make_app
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)/"private"
            initialize(folder, "8.8.8.8", 8765)  # Certificate only; listener binds loopback.
            link = json.loads((folder/"ShiftFindMyPairing.json").read_text())
            self.assertEqual(len(link["token"]), 64)
            with self.assertRaises(ValueError): initialize(folder, "8.8.8.8", 8765)
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(folder/"cert.pem", folder/"key.pem")
            server = TestServer(make_app(link["token"], None), scheme="https")
            await server.start_server(ssl=ctx)
            try:
                fingerprint = aiohttp.Fingerprint(bytes.fromhex(link["certificateSHA256"]))
                async with aiohttp.ClientSession() as client:
                    async with client.delete(server.make_url("/v1/session/"+str(uuid.uuid4())), ssl=fingerprint,
                        headers={"Authorization": "Bearer "+link["token"]}) as response:
                        self.assertEqual(response.status, 204)
                    with self.assertRaises(aiohttp.ServerFingerprintMismatch):
                        await client.get(server.make_url("/"), ssl=aiohttp.Fingerprint(bytes(32)))
            finally:
                await server.close()


if __name__ == "__main__": unittest.main()
