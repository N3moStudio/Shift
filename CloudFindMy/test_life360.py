import asyncio
import time
import unittest
from unittest.mock import AsyncMock, patch

import test_render
from test_render import Config, FakeApple, Store, make_render_app
from render_server import Owner
from reports import Report
from web_life360 import WebLife360


class FakeLife360:
    def __init__(self):
        self.choices = []
        self.target = "My profile"
        self.fetches = 0
        self.report_state = "ok"
        self.fail = False

    async def login(self, username, password):
        if self.fail:
            raise ValueError("PRIVATE PASSWORD AND PROVIDER RESPONSE")
        self.choices = [("circle", "<script>Private Circle</script>")]
        return "circle"

    async def circle(self, index):
        self.choices = [("me", "My profile")]
        return "member"

    async def select(self, index):
        self.target = self.choices[index][1]
        return "ready"

    async def fetch(self):
        self.fetches += 1
        return Report("life360", self.target, self.report_state, 37, -122,
                      time.time() - (240 if self.report_state == "old" else 0), 5, time.time())

    async def close(self):
        self.choices = []


class CloudLife360Tests(unittest.IsolatedAsyncioTestCase):
    get = test_render.RenderWebTests.get
    post = test_render.RenderWebTests.post
    unlock = test_render.RenderWebTests.unlock
    action = test_render.RenderWebTests.action
    settle = test_render.RenderWebTests.settle
    connect = test_render.RenderWebTests.connect
    payload = test_render.RenderWebTests.payload
    phone_check = test_render.RenderWebTests.phone_check

    async def asyncSetUp(self):
        from aiohttp.test_utils import TestClient, TestServer
        self.config = Config("https://test.onrender.com", "local-test-key-" + "z"*40)
        self.fake, self.life = FakeApple(), FakeLife360()
        self.store, self.life_store = Store(), Store()
        self.client = TestClient(TestServer(make_render_app(self.config, self.fake, self.store,
            interval=60, refresh_wait=.1, life_connector=self.life, life_store=self.life_store)))
        await self.client.start_server()
        self.headers = {"Host": "test.onrender.com", "Origin": self.config.origin}
        self.csrf = None

    async def asyncTearDown(self):
        await self.client.close()

    async def connect_life(self):
        if self.csrf is None:
            await self.unlock()
        response = await self.action("/life360/login", username="observer@example.test", password="dummy", consent="yes")
        self.assertEqual(response.status, 303)
        source = await self.settle("Choose Circle")
        self.assertIn("&lt;script&gt;", source)
        await self.action("/life360/circle", choice="0")
        await self.settle("Check my profile")
        await self.action("/life360/select", choice="0")
        await self.settle("Life360 ready:")

    async def test_life_only_pairing_without_apple_and_no_apple_poll(self):
        await self.connect_life()
        self.assertEqual((await self.get("/pairing")).status, 200)
        result = await (await self.phone_check(self.payload(providers=["life360"]))).json()
        self.assertEqual(result["status"], "paused")
        self.assertEqual(result["life360"]["status"], "match")
        self.assertEqual(self.fake.fetches, 0)
        self.assertEqual(self.life.fetches, 1)

    async def test_both_services_independent_when_apple_signin_expires(self):
        await self.connect()
        await self.connect_life()
        self.fake.report_state = "sign-in"
        result = await (await self.phone_check(self.payload(providers=["findmy-device", "life360"]))).json()
        self.assertEqual(result["status"], "sign-in")
        self.assertEqual(result["life360"]["status"], "match")
        self.assertIsNotNone(self.life_store.polling_id())

    async def test_life_blocked_does_not_stop_apple(self):
        await self.connect()
        await self.connect_life()
        self.life.report_state = "blocked"
        result = await (await self.phone_check(self.payload(providers=["findmy-device", "life360"]))).json()
        self.assertEqual(result["status"], "match")
        self.assertEqual(result["life360"]["status"], "blocked")
        self.assertIsNone(self.life_store.polling_id())
        self.assertIsNotNone(self.store.polling_id())

    async def test_legacy_request_never_activates_life(self):
        await self.connect_life()
        await self.phone_check(self.payload())
        self.assertIsNone(self.life_store.polling_id())
        self.assertEqual(self.life.fetches, 0)

    async def test_old_report_stays_old_and_pings_do_not_renew_either_lease(self):
        await self.connect_life()
        self.life.report_state = "old"
        result = await (await self.phone_check(self.payload(providers=["life360"]))).json()
        self.assertEqual(result["life360"]["status"], "old")
        self.store.session.seen -= 151
        self.life_store.session.seen -= 151
        response = await self.get("/healthz")
        self.assertEqual(await response.text(), "ok")
        for store in (self.store, self.life_store):
            self.assertIsNone(store.polling_id())
            self.assertEqual(store.session.history, [])
        self.assertEqual(self.life.fetches, 1)

    async def test_off_clears_report_and_delete_cannot_resurrect(self):
        await self.connect_life()
        payload = self.payload(providers=["life360"])
        await self.phone_check(payload)
        await asyncio.sleep(1.05)
        result = await (await self.phone_check(dict(payload, sequence=2, providers=[]))).json()
        self.assertEqual(result["life360"]["status"], "paused")
        self.assertIsNone(result["life360"]["report"])
        headers = {"Host": "test.onrender.com", "Authorization": "Bearer " + self.config.phone_token}
        await self.client.delete("/v1/session/" + payload["sessionID"], headers=headers)
        self.life_store.publish(payload["sessionID"], Report("life360", "me", "ok", 37, -122, time.time(), 5, time.time()).json())
        self.assertIsNone(self.life_store.report)

    async def test_life_forms_need_admin_origin_csrf_and_consent(self):
        self.assertEqual((await self.post("/life360/login", {})).status, 401)
        await self.unlock()
        self.assertEqual((await self.post("/life360/login", {"csrf": "wrong"})).status, 403)
        self.assertEqual((await self.action("/life360/login", username="test", password="dummy")).status, 400)
        self.assertEqual((await self.action("/life360/select", choice="0")).status, 400)

    async def test_exception_never_leaks_credentials_or_provider_body(self):
        await self.unlock()
        self.life.fail = True
        await self.action("/life360/login", username="observer@example.test", password="dummy", consent="yes")
        source = await self.settle("Life360 sign-in could not finish")
        for secret in ("PRIVATE PASSWORD", "observer@example.test", "dummy"):
            self.assertNotIn(secret, source)

    async def test_connection_test_reports_each_service_without_polling(self):
        await self.connect_life()
        response = await self.get("/v1/status", headers={"Host": "test.onrender.com", "Authorization": "Bearer " + self.config.phone_token})
        self.assertEqual(await response.json(), {"version": 1, "status": "sign-in", "life360": "ready"})
        self.assertEqual(self.life.fetches, 0)
        self.assertIsNone(self.life_store.session)

    async def test_slow_life_reply_cannot_block_apple_or_revive_stopped_session(self):
        await self.connect()
        await self.connect_life()
        release = asyncio.Event()
        original = self.life.fetch
        async def slow():
            await release.wait()
            return await original()
        self.life.fetch = slow
        payload = self.payload(providers=["findmy-device", "life360"])
        try:
            result = await (await asyncio.wait_for(self.phone_check(payload), .7)).json()
            self.assertEqual(result["status"], "match")
            self.assertEqual(result["life360"]["status"], "waiting")
            await self.action("/life360/disconnect")
        finally:
            release.set()
        await self.settle("Sign in to Life360")
        self.assertIsNone(self.life_store.report)
        self.assertEqual(self.store.snapshot()["status"], "match")


class Life360AdapterTests(unittest.IsolatedAsyncioTestCase):
    async def test_selected_profile_read_only_timestamp_conversion_and_cleanup(self):
        adapter = WebLife360()
        api = AsyncMock()
        api.get_circles.return_value = [{"id": "c1", "name": "Home"}]
        api.get_circle_members.return_value = [{"id": "m1", "firstName": "Me"}, {"id": "m2", "firstName": "Other"}]
        api.get_circle_member.return_value = {"features": {"shareLocation": "1"}, "location": {
            "latitude": 37, "longitude": -122, "timestamp": time.time()-240, "accuracy": 10}}
        with patch("life360.Life360", return_value=api) as factory:
            try:
                self.assertEqual(await adapter.login("observer", "dummy"), "circle")
                self.assertEqual(await adapter.circle(0), "member")
                self.assertEqual(await adapter.select(0), "ready")
                report = await adapter.fetch()
                self.assertEqual(report.state, "old")
                self.assertAlmostEqual(report.accuracy, 3.048)
                api.get_circle_member.assert_awaited_once_with("c1", "m1")
                api.request_location_update.assert_not_called()
                self.assertEqual(factory.call_args.kwargs, {"max_retries": 0, "verbosity": 0})
                session = adapter.session
            finally:
                await adapter.close()
            self.assertTrue(session.closed)
            self.assertIsNone(adapter.api)
            self.assertEqual(adapter.choices, [])

    async def test_pinned_library_has_required_read_methods(self):
        import inspect
        from life360 import Life360
        for name in ("login_by_username", "get_circles", "get_circle_members", "get_circle_member"):
            self.assertTrue(inspect.iscoroutinefunction(getattr(Life360, name)))

