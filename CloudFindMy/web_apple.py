"""Single-owner Apple sign-in adapter. Called serially on a worker thread.

No password persistence, terminal prompts, account controls, or family lookup.
"""
from pathlib import Path
import tempfile
import time

from reports import apple_report, missing


class AppleSetupError(Exception):
    """Only fixed, user-facing messages belong in this exception."""


class WebApple:
    def __init__(self):
        self.api = None
        self.manager = None
        self.cookies = None
        self.choices = []
        self.device_id = None
        self.target = "Selected iPhone"

    def login(self, email, password):
        from pyicloud import PyiCloudService
        from requests.adapters import HTTPAdapter

        class TimedAdapter(HTTPAdapter):
            def send(self, request, **kwargs):
                if kwargs.get("timeout") is None:
                    kwargs["timeout"] = (10, 20)
                return super().send(request, **kwargs)

        self.close()
        ram = "/dev/shm" if Path("/dev/shm").is_dir() else None
        self.cookies = tempfile.TemporaryDirectory(prefix="shift-apple-", dir=ram)
        self.api = PyiCloudService(email, password, cookie_directory=self.cookies.name,
                                  with_family=False, accept_terms=False,
                                  refresh_interval=86400, authenticate=False)
        self.api.session.mount("https://", TimedAdapter())
        self.api.authenticate()
        if self.api.requires_2fa:
            if self.api.security_key_names:
                raise AppleSetupError("This helper cannot use your physical security key. Keep that protection enabled.")
            self.api.request_2fa_code()
            return "code"
        if self.api.requires_2sa:
            raise AppleSetupError("This older Apple verification method is not supported by the browser helper.")
        return self.load_devices()

    def verify(self, code):
        if self.api is None:
            raise AppleSetupError("Sign in to Apple again first.")
        if not self.api.validate_2fa_code(code):
            return "code"
        if not self.api.is_trusted_session and not self.api.trust_session():
            raise AppleSetupError("Apple could not finish verification. Sign in again.")
        return self.load_devices()

    def load_devices(self):
        self.manager = self.api.devices
        self.manager.stop_event.set()
        self.choices = []
        for identifier, device in self.manager.devices.items():
            self.choices.append((identifier, str(device.status().get("name") or "Unnamed device")[:120]))
        if not self.choices:
            raise AppleSetupError("Apple returned no devices. Check Find My Devices on iCloud.com, then try again.")
        return "device"

    def select(self, index):
        if not 0 <= index < len(self.choices):
            raise AppleSetupError("Choose one of the listed devices.")
        self.device_id, self.target = self.choices[index]
        return "ready"

    def fetch(self):
        if self.manager is None or self.device_id is None:
            return missing("findmy-device", self.target, "sign-in")
        try:
            self.manager.refresh(locate=True)
        finally:
            # pyicloud may restart its own monitor on refresh. Only Shift's lease
            # is allowed to schedule location polling for this helper.
            self.manager.stop_event.set()
        device = self.manager.devices.get(self.device_id)
        if device is None:
            return missing("findmy-device", self.target)
        return apple_report(self.target, device.location, now=time.time())

    def close(self):
        if self.manager is not None:
            self.manager.stop_event.set()
            self.manager = None
        if self.api is not None:
            self.api.session.close()
            self.api = None
        if self.cookies is not None:
            self.cookies.cleanup()
            self.cookies = None
        self.choices = []
        self.device_id = None
        self.target = "Selected iPhone"
