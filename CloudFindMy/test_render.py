import asyncio
import hashlib
import hmac
import json
from pathlib import Path
import re
import sys
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).parent))
from render_server import Config, Limit, COOKIE, Owner, make_render_app
from core import Store
from reports import Report
from web_apple import WebApple, AppleSetupError


class RenderConfigTests(unittest.TestCase):
    def test_only_render_https_origins_and_strong_key(self):
        key = "test-owner-key-" + "a"*40
        for origin in ("http://test.onrender.com", "https://localhost", "https://127.0.0.1",
                       "https://onrender.com", "https://a.b.onrender.com", "https://-test.onrender.com",
                       "https://test.onrender.com:8765", "https://test.onrender.com.evil.test",
                       "https://test.onrender.com?key=x", "https://test.onrender.com/path",
                       "https://test.onrender.com#x", "https://user@test.onrender.com"):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                Config(origin, key)
        for invalid in ("", "short", " "*40, "a"*257, "é"*40):
            with self.assertRaises(ValueError):
                Config("https://test.onrender.com", invalid)

    def test_pairing_survives_restart_but_not_key_rotation(self):
        config = Config("https://test.onrender.com", "a"*48)
        self.assertEqual(config.pairing, Config(config.origin, config.admin_key).pairing)
        self.assertNotEqual(config.phone_token, Config(config.origin, "b"*48).phone_token)
        self.assertNotEqual(config.phone_token, config.admin_key)
        self.assertEqual(config.pairing["version"], 2)
        self.assertEqual(config.pairing["certificateSHA256"], "")

    def test_rate_limit_expires_without_unbounded_storage(self):
        now = [0]
        limit = Limit(2, 60, clock=lambda: now[0])
        self.assertTrue(limit.take())
        self.assertTrue(limit.take())
        for _ in range(100):
            self.assertFalse(limit.take())
        self.assertEqual(len(limit.events), 2)
        now[0] = 60
        self.assertTrue(limit.take())


class AppleAdapterTests(unittest.TestCase):
    def setUp(self):
        from unittest.mock import Mock, patch
        from types import SimpleNamespace
        self.adapter = WebApple()
        self.device = SimpleNamespace(status=lambda: {"name": "My iPhone"}, location={
            "latitude": 37, "longitude": -122, "timeStamp": 1000000, "horizontalAccuracy": 5})
        self.manager = SimpleNamespace(devices={"one": self.device}, stop_event=Mock(), refresh=Mock())
        self.api = SimpleNamespace(session=Mock(), authenticate=Mock(), requires_2fa=True,
            security_key_names=[], request_2fa_code=Mock(), requires_2sa=False,
            validate_2fa_code=Mock(return_value=True), is_trusted_session=False,
            trust_session=Mock(return_value=True), devices=self.manager)
        self.factory = patch("pyicloud.PyiCloudService", return_value=self.api)
        self.mock_factory = self.factory.start()

    def tearDown(self):
        self.adapter.close()
        self.factory.stop()

    def test_two_factor_select_read_only_report_and_stop_library_monitor(self):
        self.assertEqual(self.adapter.login("owner@example.test", "dummy"), "code")
        self.assertFalse(self.mock_factory.call_args.kwargs["with_family"])
        self.assertFalse(self.mock_factory.call_args.kwargs["accept_terms"])
        self.assertEqual(self.adapter.verify("123456"), "device")
        self.assertEqual(self.adapter.select(0), "ready")
        self.manager.stop_event.reset_mock()
        report = self.adapter.fetch()
        self.assertEqual(report.locatedAt, 1000)  # Downloading it must not make it fresh.
        self.assertEqual(report.state, "old")
        self.manager.refresh.assert_called_once_with(locate=True)
        self.manager.stop_event.set.assert_called_once()
        folder = self.adapter.cookies.name
        self.adapter.close()
        self.assertFalse(Path(folder).exists())
        self.assertIsNone(self.adapter.api)

    def test_security_keys_do_not_silently_downgrade(self):
        self.api.security_key_names = ["My security key"]
        with self.assertRaises(AppleSetupError):
            self.adapter.login("owner@example.test", "dummy")
        self.api.request_2fa_code.assert_not_called()

    def test_rejected_code_keeps_verification_step(self):
        self.adapter.login("owner@example.test", "dummy")
        self.api.validate_2fa_code.return_value = False
        self.assertEqual(self.adapter.verify("999999"), "code")
        self.assertIsNone(self.adapter.manager)

    def test_refresh_failure_still_stops_monitor(self):
        self.api.requires_2fa = False
        self.adapter.login("owner@example.test", "dummy")
        self.adapter.select(0)
        self.manager.stop_event.reset_mock()
        self.manager.refresh.side_effect = RuntimeError("failed")
        with self.assertRaises(RuntimeError):
            self.adapter.fetch()
        self.manager.stop_event.set.assert_called_once()

    def test_refresh_reads_selected_device_updated_data_not_first_device_or_old_object(self):
        from types import SimpleNamespace
        self.api.requires_2fa = False
        self.adapter.login("owner@example.test", "dummy")
        self.adapter.select(0)
        fresh = SimpleNamespace(location={"latitude": 38, "longitude": -121,
            "timeStamp": 1001000, "horizontalAccuracy": 7})
        other = SimpleNamespace(location={"latitude": 0, "longitude": 0,
            "timeStamp": 1002000, "horizontalAccuracy": 5})
        def refreshed(**kwargs):
            self.manager.devices = {"other": other, "one": fresh}
        self.manager.refresh.side_effect = refreshed
        report = self.adapter.fetch()
        self.assertEqual(report.latitude, 38)
        self.assertEqual(report.longitude, -121)
        self.assertEqual(report.locatedAt, 1001)

    def test_missing_selected_device_does_not_silently_switch_to_another(self):
        self.api.requires_2fa = False
        self.adapter.login("owner@example.test", "dummy")
        self.adapter.select(0)
        self.manager.devices = {"other": self.device}
        report = self.adapter.fetch()
        self.assertEqual(report.state, "unavailable")
        self.assertIsNone(report.latitude)


class FakeApple:
    def __init__(self):
        self.choices = []
        self.target = "Selected iPhone"
        self.fetches = 0
        self.logins = 0
        self.fail = False
        self.report_state = "ok"
        self.ready = False

    def login(self, email, password):
        self.logins += 1
        if self.fail:
            raise ValueError("PRIVATE APPLE RESPONSE AND PASSWORD MUST NEVER LEAK")
        return "code"

    def verify(self, code):
        if code != "123456":
            return "code"
        self.choices = [("hidden-device-id", '<script>alert("name")</script> iPhone')]
        return "device"

    def select(self, index):
        _, self.target = self.choices[index]
        self.ready = True
        return "ready"

    def close(self):
        self.choices, self.target, self.ready = [], "Selected iPhone", False

    def fetch(self):
        self.fetches += 1
        return Report("findmy-device", self.target, self.report_state,
                      37, -122, time.time(), 5, time.time())


class RenderRaceTests(unittest.IsolatedAsyncioTestCase):
    async def test_disconnect_while_fetching_cannot_restore_an_old_match(self):
        import threading
        entered, release = threading.Event(), threading.Event()
        class SlowApple(FakeApple):
            def fetch(self):
                entered.set()
                release.wait(3)
                return super().fetch()
        store = Store()
        connector = SlowApple()
        owner = Owner(connector, store)
        owner.stage, store.auth_state = "ready", None
        now = time.time()
        sid = str(uuid.uuid4())
        store.update(dict(version=1, sessionID=sid, startedAt=now-1, sentAt=now,
                          sequence=1, active=True, samples=[]))
        task = asyncio.create_task(owner.fetch(sid))
        try:
            self.assertTrue(await asyncio.to_thread(entered.wait, 1))
            owner.start("close")
        finally:
            release.set()
        await task
        await owner.job
        self.assertIsNone(store.report)
        self.assertEqual(store.snapshot()["status"], "sign-in")


class RenderWebTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        from aiohttp.test_utils import TestClient, TestServer
        self.config = Config("https://test.onrender.com", "local-test-key-" + "z"*40)
        self.fake = FakeApple()
        self.store = Store()
        self.client = TestClient(TestServer(make_render_app(self.config, self.fake, self.store, interval=60, refresh_wait=.05)))
        await self.client.start_server()
        self.headers = {"Host": "test.onrender.com", "Origin": self.config.origin}
        self.csrf = None

    async def asyncTearDown(self):
        await self.client.close()

    async def get(self, path, **kwargs):
        return await self.client.get(path, headers=kwargs.pop("headers", self.headers), **kwargs)

    async def post(self, path, data=None, **kwargs):
        return await self.client.post(path, data=data, headers=kwargs.pop("headers", self.headers),
                                      allow_redirects=False, **kwargs)

    async def unlock(self):
        response = await self.post("/login", {"key": self.config.admin_key})
        self.assertEqual(response.status, 303)
        cookie = response.cookies[COOKIE]
        self.assertTrue(cookie["secure"])
        self.assertTrue(cookie["httponly"])
        self.assertEqual(cookie["samesite"], "Strict")
        self.headers["Cookie"] = f"{COOKIE}={cookie.value}"
        source = await (await self.get("/")).text()
        self.csrf = re.search(r'name="csrf" value="([^"]+)"', source)[1]

    async def action(self, path, **fields):
        return await self.post(path, {"csrf": self.csrf, **fields})

    async def settle(self, expected):
        for _ in range(100):
            source = await (await self.get("/")).text()
            if expected in source:
                return source
            await asyncio.sleep(.01)
        self.fail("Browser did not reach expected state: " + expected)

    async def connect(self):
        await self.unlock()
        self.assertEqual((await self.action("/apple/login", email="owner@example.test", password="dummy-only")).status, 303)
        await self.settle("Check your Apple device")
        self.assertEqual((await self.action("/apple/verify", code="123456")).status, 303)
        source = await self.settle("Choose your iPhone")
        self.assertNotIn('<script>alert("name")</script>', source)
        self.assertIn("&lt;script&gt;", source)
        self.assertEqual((await self.action("/apple/select", device="0")).status, 303)
        await self.settle("Your helper is ready")

    def payload(self, **overrides):
        now = time.time()
        return dict(dict(version=1, sessionID=str(uuid.uuid4()), startedAt=now-1,
                         sentAt=now, sequence=1, active=True,
                         samples=[dict(latitude=37, longitude=-122, confirmedAt=now-.5)]), **overrides)

    async def phone_check(self, payload):
        return await self.client.post("/v1/check", json=payload,
            headers={"Host": "test.onrender.com", "Authorization": "Bearer " + self.config.phone_token})

    async def test_connection_status_requires_phone_key_without_starting_location_checks(self):
        self.assertEqual((await self.get("/v1/status")).status, 401)
        headers = {"Host": "test.onrender.com", "Authorization": "Bearer " + self.config.admin_key}
        self.assertEqual((await self.get("/v1/status", headers=headers)).status, 401)
        headers["Authorization"] = "Bearer " + self.config.phone_token
        response = await self.get("/v1/status", headers=headers)
        self.assertEqual(await response.json(), {"version": 1, "status": "sign-in", "life360": "sign-in"})
        await self.connect()
        response = await self.get("/v1/status", headers=headers)
        self.assertEqual(await response.json(), {"version": 1, "status": "ready", "life360": "sign-in"})
        self.assertIsNone(self.store.polling_id())
        self.assertEqual(self.fake.fetches, 0)

    async def test_public_page_and_health_never_reveal_keys_or_poll_apple(self):
        for path in ("/", "/style.css", "/healthz"):
            response = await self.get(path)
            self.assertEqual(response.status, 200)
            body = await response.text()
            self.assertNotIn(self.config.admin_key, body)
            self.assertNotIn(self.config.phone_token, body)
            self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(self.fake.fetches, 0)
        self.assertEqual((await self.get("/pairing")).status, 401)
        self.assertEqual((await self.post("/apple/login", {"email": "x", "password": "x"})).status, 401)

    async def test_untrusted_host_origin_and_csrf_are_rejected(self):
        self.assertEqual((await self.get("/", headers={"Host": "evil.test"})).status, 400)
        self.assertEqual((await self.post("/login", {"key": self.config.admin_key},
            headers={"Host": "test.onrender.com", "Origin": "https://evil.test"})).status, 403)
        await self.unlock()
        self.assertEqual((await self.post("/apple/login", {"csrf": "wrong"})).status, 403)
        self.assertEqual(self.fake.logins, 0)
        self.assertIn("frame-ancestors 'none'", (await self.get("/")).headers["Content-Security-Policy"])

    async def test_native_form_policy_preserves_origin_without_accepting_opaque_origins(self):
        # Native browser forms obey this response policy; the HTTP test client
        # does not, so explicitly guard against the policy that caused Origin: null.
        response = await self.get("/")
        self.assertEqual(response.headers["Referrer-Policy"], "same-origin")
        for origin in (None, "null", "https://evil.test"):
            headers = {"Host": "test.onrender.com"}
            if origin is not None:
                headers["Origin"] = origin
            response = await self.post("/login", {"key": self.config.admin_key}, headers=headers)
            self.assertEqual(response.status, 403)
            self.assertNotIn(COOKIE, response.cookies)
        await self.unlock()
        response = await self.get("/")
        self.assertEqual(response.headers["Referrer-Policy"], "same-origin")
        self.assertIn("Connect your Apple Account", await response.text())

    async def test_phone_credentials_do_not_unlock_browser_and_admin_key_is_not_api_key(self):
        self.assertEqual((await self.post("/login", {"key": self.config.phone_token})).status, 401)
        response = await self.client.post("/v1/check", json=self.payload(),
            headers={"Host": "test.onrender.com", "Authorization": "Bearer " + self.config.admin_key})
        self.assertEqual(response.status, 401)

    async def test_key_guesses_rate_limited(self):
        for _ in range(10):
            self.assertEqual((await self.post("/login", {"key": "incorrect"})).status, 401)
        self.assertEqual((await self.post("/login", {"key": "incorrect"})).status, 429)

    async def test_browser_flow_pairing_and_lock_page_does_not_disconnect_apple(self):
        await self.connect()
        response = await self.get("/pairing")
        self.assertEqual(response.status, 200)
        self.assertEqual(await response.json(), self.config.pairing)
        self.assertIn("attachment", response.headers["Content-Disposition"])
        self.assertEqual(self.fake.fetches, 0)
        await self.action("/logout")
        self.assertEqual((await self.get("/pairing")).status, 401)
        self.assertTrue(self.fake.ready)

    async def test_wrong_code_can_retry_and_device_index_is_validated(self):
        await self.unlock()
        await self.action("/apple/login", email="owner@example.test", password="dummy-only")
        await self.settle("Check your Apple device")
        await self.action("/apple/verify", code="999999")
        await self.settle("That code was not accepted")
        await self.action("/apple/verify", code="123456")
        await self.settle("Choose your iPhone")
        self.assertEqual((await self.action("/apple/select", device="999")).status, 400)

    async def test_failure_messages_never_echo_apple_exception_or_credentials(self):
        await self.unlock()
        self.fake.fail = True
        await self.action("/apple/login", email="owner@example.test", password="dummy-only")
        source = await self.settle("Could not finish that Apple step")
        self.assertNotIn("PRIVATE APPLE RESPONSE", source)
        self.assertNotIn("dummy-only", source)
        self.assertNotIn("owner@example.test", source)

    async def test_after_restart_phone_gets_signin_needed_not_a_match(self):
        response = await self.phone_check(self.payload())
        self.assertEqual(response.status, 200)
        result = await response.json()
        self.assertEqual(result["status"], "sign-in")
        self.assertIsNone(result["report"])

    async def test_check_now_returns_due_refresh_in_same_reply(self):
        await self.connect()
        response = await self.phone_check(self.payload())
        result = await response.json()
        self.assertIsNotNone(result["report"])
        self.assertEqual(result["status"], "match")
        self.assertEqual(self.fake.fetches, 1)

    async def test_check_now_replaces_cached_old_report_when_apple_has_new_data(self):
        await self.connect()
        payload = self.payload()
        self.store.update(dict(payload, sequence=1))
        old_time = time.time() - 240
        self.store.report = Report("findmy-device", self.fake.target, "old", 37, -122,
                                   old_time, 5, time.time()).json()
        response = await self.phone_check(dict(payload, sequence=2))
        result = await response.json()
        self.assertEqual(result["status"], "match")
        self.assertGreater(result["report"]["locatedAt"], old_time)

    async def test_repeated_checks_share_minute_cooldown_and_preserve_old_apple_time(self):
        await self.connect()
        old_time = time.time() - 240
        def old_report():
            self.fake.fetches += 1
            return Report("findmy-device", self.fake.target, "old", 37, -122, old_time, 5, time.time())
        self.fake.fetch = old_report
        payload = self.payload()
        first = await (await self.phone_check(payload)).json()
        self.assertEqual(first["status"], "old")
        self.assertEqual(first["report"]["locatedAt"], old_time)
        await asyncio.sleep(1.05)
        second = await (await self.phone_check(dict(payload, sequence=2))).json()
        self.assertEqual(second["report"]["locatedAt"], old_time)
        self.assertEqual(self.fake.fetches, 1)

    async def test_slow_refresh_is_bounded_shared_and_finishes_after_phone_reply(self):
        import threading
        await self.connect()
        release = threading.Event()
        original = self.fake.fetch
        calls = []
        def slow_report():
            calls.append(True)
            release.wait(3)
            return original()
        self.fake.fetch = slow_report
        payload = self.payload()
        try:
            first = await asyncio.wait_for(self.phone_check(payload), .5)
            self.assertEqual((await first.json())["status"], "waiting")
            await asyncio.sleep(1.05)
            second = await asyncio.wait_for(self.phone_check(dict(payload, sequence=2)), .5)
            self.assertEqual((await second.json())["status"], "waiting")
            self.assertEqual(len(calls), 1)
        finally:
            release.set()
        for _ in range(100):
            if self.store.report:
                break
            await asyncio.sleep(.01)
        self.assertEqual(self.store.snapshot()["status"], "match")
        self.assertEqual(len(calls), 1)

    async def test_poll_only_with_phone_lease_then_disconnect_clears_match(self):
        await self.connect()
        payload = self.payload()
        response = await self.phone_check(payload)
        self.assertEqual(response.status, 200)
        for _ in range(150):
            if self.store.report:
                break
            await asyncio.sleep(.01)
        self.assertEqual(self.store.snapshot()["status"], "match")
        self.assertGreater(self.fake.fetches, 0)
        await self.action("/apple/disconnect")
        self.assertIsNone(self.store.report)
        self.assertEqual(self.store.snapshot()["status"], "sign-in")
        self.assertEqual(self.store.session.history, [])
        await self.settle("Connect your Apple Account")

    async def test_health_ping_does_not_extend_phone_lease(self):
        self.store.update(self.payload())
        self.store.session.seen -= 151
        await self.get("/healthz")
        self.assertIsNone(self.store.polling_id())
        self.assertEqual(self.store.session.history, [])
        self.assertEqual(self.fake.fetches, 0)

    async def test_expired_apple_login_stops_polling_and_shows_signin(self):
        await self.connect()
        self.fake.report_state = "sign-in"
        await self.phone_check(self.payload())
        for _ in range(150):
            if self.store.auth_state == "sign-in":
                break
            await asyncio.sleep(.01)
        self.assertEqual(self.store.snapshot()["status"], "sign-in")
        self.assertIsNone(self.store.polling_id())
        await self.settle("Apple sign-in needs attention")
        self.assertFalse(self.fake.ready)

    async def test_malformed_and_oversize_payloads_do_not_return_secrets(self):
        headers = {"Host": "test.onrender.com", "Authorization": "Bearer " + self.config.phone_token}
        response = await self.client.post("/v1/check", data="{bad", headers=headers)
        self.assertEqual(response.status, 400)
        await asyncio.sleep(1.05)
        response = await self.client.post("/v1/check", data="x"*(513*1024), headers=headers)
        self.assertEqual(response.status, 413)


if __name__ == "__main__":
    unittest.main()
