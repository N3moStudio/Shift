"""Memory-only, read-only Life360 observer adapter for the browser helper."""
import time

from reports import life360_report, missing


class Life360SetupError(Exception):
    """Fixed messages only: never expose provider responses or credentials."""


class WebLife360:
    def __init__(self):
        self.session = self.api = None
        self.choices = []
        self.circle_id = self.member_id = None
        self.target = "Selected profile"

    async def login(self, username, password):
        from aiohttp import ClientSession, ClientTimeout
        from life360 import Life360
        await self.close()
        self.session = ClientSession(timeout=ClientTimeout(total=20))
        self.api = Life360(self.session, max_retries=0, verbosity=0)
        await self.api.login_by_username(username, password)
        circles = await self.api.get_circles()
        self.choices = [(str(c["id"]), str(c.get("name") or "Circle")[:120]) for c in circles]
        if not self.choices:
            raise Life360SetupError("No Circles were returned. Check the observer account in Life360, then sign in again.")
        return "circle"

    async def circle(self, index):
        if not self.api or not 0 <= index < len(self.choices):
            raise Life360SetupError("Sign in and choose a listed Circle first.")
        self.circle_id = self.choices[index][0]
        members = await self.api.get_circle_members(self.circle_id)
        self.choices = [(str(m["id"]), (" ".join(str(m.get(k) or "") for k in
                         ("firstName", "lastName")).strip() or "Profile")[:120]) for m in members]
        if not self.choices:
            raise Life360SetupError("No profiles were returned. Check that your phone is in this Circle.")
        return "member"

    async def select(self, index):
        if not self.circle_id or not 0 <= index < len(self.choices):
            raise Life360SetupError("Choose your own listed profile.")
        self.member_id, self.target = self.choices[index]
        return "ready"

    async def fetch(self):
        if not self.api or not self.member_id:
            return missing("life360", self.target, "sign-in")
        # Never request a device ping, change a Circle, or alter location sharing.
        member = await self.api.get_circle_member(self.circle_id, self.member_id)
        return life360_report(self.target, member, now=time.time())

    async def close(self):
        if self.session is not None:
            await self.session.close()
        self.session = self.api = None
        self.choices = []
        self.circle_id = self.member_id = None
        self.target = "Selected profile"
