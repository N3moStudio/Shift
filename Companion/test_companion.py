import json
import unittest
from unittest.mock import patch
from reports import apple_report, life360_report, missing, failure_state
from companion import ProviderWorker, private_ipv4


class ReportsTests(unittest.TestCase):
    def apple(self, **overrides):
        return {"latitude": 37, "longitude": -122, "timeStamp": 995000,
                "horizontalAccuracy": 5, "isOld": False, **overrides}

    def life(self, **overrides):
        return {"features": {"shareLocation": "1"}, "location": {
            "latitude": "37", "longitude": "-122", "timestamp": "995", "accuracy": "30", **overrides}}

    def test_apple_milliseconds_and_coordinates(self):
        report = apple_report("Phone", self.apple(), now=1000)
        self.assertEqual(report.state, "ok")
        self.assertEqual(report.locatedAt, 995)

    def test_download_does_not_refresh_location_time(self):
        report = apple_report("Phone", self.apple(timeStamp=500000), now=1000)
        self.assertEqual(report.state, "old")
        self.assertEqual(report.locatedAt, 500)
        self.assertEqual(report.fetchedAt, 1000)

    def test_provider_old_flag_is_honored(self):
        self.assertEqual(apple_report("Phone", self.apple(isOld=True), now=1000).state, "old")

    def test_life360_feet_converted_to_meters(self):
        report = life360_report("Me", self.life(), now=1000)
        self.assertEqual(report.state, "ok")
        self.assertAlmostEqual(report.accuracy, 9.144)

    def test_life360_heartbeat_not_substituted_for_location_timestamp(self):
        member = self.life(timestamp="500")
        member["lastUpdated"] = 1000
        self.assertEqual(life360_report("Me", member, now=1000).state, "old")

    def test_location_sharing_off_is_unavailable(self):
        member = self.life(); member["features"]["shareLocation"] = "0"
        self.assertEqual(life360_report("Me", member, now=1000).state, "unavailable")

    def test_missing_timestamp_and_accuracy_never_fabricated(self):
        for key in ("timeStamp", "horizontalAccuracy", "latitude", "longitude"):
            raw = self.apple(); del raw[key]
            self.assertEqual(apple_report("Phone", raw, now=1000).state, "unavailable")

    def test_bad_measurements_are_unavailable_and_json_safe(self):
        for raw in (self.apple(latitude=float("nan")), self.apple(longitude=190),
                    self.apple(horizontalAccuracy=-1), self.apple(timeStamp=1001000),
                    self.apple(latitude=True)):
            report = apple_report("Phone", raw, now=1000)
            self.assertEqual(report.state, "unavailable")
            json.dumps(report.json(), allow_nan=False)

    def test_missing_location_is_unavailable(self):
        self.assertEqual(apple_report("Phone", None, now=1000).state, "unavailable")
        self.assertEqual(life360_report("Me", {}, now=1000).state, "unavailable")

    def test_failure_replaces_prior_success_and_auth_stops_worker(self):
        class Unauthorized(Exception): pass
        class Connector:
            provider, target = "life360", "Me"
            def fetch(self): raise Unauthorized("never display a raw secret")
        worker = ProviderWorker(Connector())
        worker.report = life360_report("Me", self.life(), now=1000)
        self.assertFalse(worker.once())
        self.assertEqual(worker.snapshot().state, "sign-in")
        self.assertIsNone(worker.snapshot().latitude)
        self.assertNotIn("secret", json.dumps(worker.snapshot().json()))

    def test_service_blocks_do_not_retry(self):
        class RateLimited(Exception): pass
        self.assertEqual(failure_state(RateLimited()), "blocked")
        self.assertEqual(failure_state(TimeoutError()), "unavailable")

    def test_apple_exception_code_is_classified_without_exposing_message(self):
        class AppleAPIError(Exception):
            def __init__(self, code): self.code = code
        self.assertEqual(failure_state(AppleAPIError(401)), "sign-in")
        self.assertEqual(failure_state(AppleAPIError("403")), "blocked")
        self.assertEqual(failure_state(AppleAPIError(429)), "blocked")
        self.assertEqual(failure_state(AppleAPIError(500)), "unavailable")

    def test_only_private_ipv4_is_accepted(self):
        self.assertEqual(private_ipv4("192.168.2.10"), "192.168.2.10")
        for host in ("8.8.8.8", "0.0.0.0", "127.0.0.1", "evil.example", "::1"):
            with self.assertRaises(ValueError): private_ipv4(host)


if __name__ == "__main__":
    unittest.main()
