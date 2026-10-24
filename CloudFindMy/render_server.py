"""Render entry point: private browser setup, normal HTTPS, memory-only checks."""
from __future__ import annotations

import asyncio
from collections import deque
from contextlib import suppress
from dataclasses import dataclass
import hashlib
import hmac
import html
import inspect
import json
import logging
import os
from pathlib import Path
import re
import secrets
import sys
import time
from urllib.parse import urlsplit

from aiohttp import web

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Companion"))
from reports import failure_state, missing
from core import Store, validate_request
from web_apple import AppleSetupError, WebApple
from web_life360 import Life360SetupError, WebLife360

COOKIE = "__Host-shift-admin"
RENDER_HOST = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.onrender\.com\Z")


@dataclass(frozen=True)
class Config:
    origin: str
    admin_key: str

    def __post_init__(self):
        url = urlsplit(self.origin)
        if (url.scheme != "https" or not RENDER_HOST.fullmatch(url.netloc)
                or url.path or url.query or url.fragment):
            raise ValueError("RENDER_EXTERNAL_URL must be the service's HTTPS onrender.com address")
        if not (32 <= len(self.admin_key) <= 256 and self.admin_key.isascii()
                and all(33 <= ord(c) <= 126 for c in self.admin_key)):
            raise ValueError("Set SHIFT_ADMIN_KEY to a generated secret of at least 32 characters")

    @property
    def phone_token(self):
        return hmac.new(self.admin_key.encode(), b"shift-render-phone-v2", hashlib.sha256).hexdigest()

    @property
    def pairing(self):
        return {"version": 2, "kind": "shift-findmy-render", "endpoint": self.origin,
                "token": self.phone_token, "certificateSHA256": ""}


class Limit:
    def __init__(self, count, seconds, clock=time.monotonic):
        self.count, self.seconds, self.clock = count, seconds, clock
        self.events = deque()

    def take(self):
        now = self.clock()
        while self.events and now - self.events[0] >= self.seconds:
            self.events.popleft()
        if len(self.events) >= self.count:
            return False
        self.events.append(now)
        return True


class Owner:
    """All UI/store state belongs to the event loop; Apple work is serialized."""
    def __init__(self, connector, store, provider="findmy-device"):
        self.connector, self.store = connector, store
        self.provider = provider
        self.name = "Apple" if provider == "findmy-device" else "Life360"
        self.stage, self.message = "sign-in", ""
        self.devices, self.target = [], ""
        self.job = None
        self.lock = asyncio.Lock()
        self.generation = 0
        self.store.auth_state = "sign-in"

    @property
    def busy(self):
        return self.job is not None and not self.job.done()

    def start(self, action, *args):
        if self.busy:
            raise web.HTTPConflict(text="A step is already running. Wait for it to finish.")
        self.generation += 1
        self.store.report = None
        self.store.auth_state = "sign-in"
        # Discard uploaded history as soon as Apple identity is changed or disconnected.
        if self.store.session:
            self.store.session.history = []
        self.message = ""
        self.job = asyncio.create_task(self.run(action, args))

    async def call(self, action, *args):
        method = getattr(self.connector, action)
        if inspect.iscoroutinefunction(method):
            # Cancels async requests cleanly; Apple uses its own bounded HTTP adapter.
            return await asyncio.wait_for(method(*args), timeout=45)
        return await asyncio.to_thread(method, *args)

    async def run(self, action, args):
        async with self.lock:
            try:
                result = await self.call(action, *args)
                self.stage = result or "sign-in"
                self.devices = [name for _, name in self.connector.choices]
                self.target = self.connector.target if self.stage == "ready" else ""
                self.store.auth_state = None if self.stage == "ready" else "sign-in"
                if action == "verify" and self.stage == "code":
                    self.message = "That code was not accepted. Check the code and try again."
            except Exception as error:
                self.stage, self.devices, self.target = "sign-in", [], ""
                self.store.auth_state = "sign-in"
                if isinstance(error, (AppleSetupError, Life360SetupError)):
                    self.message = str(error)
                elif failure_state(error) == "blocked":
                    self.message = f"{self.name} declined or limited this sign-in. Check the official app, then try later."
                elif self.provider == "life360":
                    self.message = "Life360 sign-in could not finish. Check the observer credentials in the official app. Extra verification or blocked unofficial access is not supported; do not disable account protection."
                else:
                    self.message = "Could not finish that Apple step. Check your connection and sign in again."
                with suppress(Exception):
                    await self.call("close")

    async def fetch(self, sid):
        generation = self.generation
        async with self.lock:
            if self.busy or self.stage != "ready" or generation != self.generation:
                return
            try:
                report = (await self.call("fetch")).json()
            except Exception as error:
                report = missing(self.provider, self.target, failure_state(error)).json()
            if generation != self.generation:
                return
            self.store.publish(sid, report)
            if self.store.auth_state:
                self.stage = "sign-in"
                self.devices, self.target = [], ""
                self.message = f"{self.name} sign-in needs attention. Check the official app, then reconnect below."
                with suppress(Exception):
                    await self.call("close")


def form(action, fields, label, csrf="", secondary=False):
    hidden = f'<input type="hidden" name="csrf" value="{html.escape(csrf)}">' if csrf else ""
    style = ' class="secondary"' if secondary else ""
    return f'<form method="post" action="{action}">{hidden}{fields}<button{style}>{label}</button></form>'


def life360_panel(owner, csrf):
    notice = f'<p role="alert" class="notice">{html.escape(owner.message)}</p>' if owner.message else ""
    if owner.busy:
        body = "<p>Finishing your Life360 step… This page will refresh.</p>"
    elif owner.stage in ("circle", "member"):
        is_circle = owner.stage == "circle"
        label = "Circle" if is_circle else "Your profile"
        options = "".join(f'<option value="{i}">{html.escape(name)}</option>' for i, name in enumerate(owner.devices))
        body = form("/life360/" + ("circle" if is_circle else "select"),
                    f'<label>{label}<select name="choice">{options}</select></label>',
                    "Choose Circle" if is_circle else "Check my profile", csrf)
    elif owner.stage == "ready":
        body = f'<p>Life360 ready: {html.escape(owner.target)}</p><p class="muted">Enable Life360 checks in Shift. Ready does not mean a location matched.</p>'
    else:
        body = ('<p>Use a separate, consenting Circle member’s observer account to check your own phone. Signing in with your phone’s account can sign it out.</p>' +
                form("/life360/login",
                     '<label>Observer email or phone<input name="username" autocomplete="username" maxlength="254" required></label>'
                     '<label>Password<input name="password" type="password" autocomplete="current-password" maxlength="1024" required></label>'
                     '<label><input class="consent" type="checkbox" name="consent" value="yes" required> I have permission to use this observer account and will select my own profile.</label>',
                     "Sign in to Life360", csrf))
        body += '<p class="muted">Optional, unofficial connection. No Life360 subscription required by Shift. Life360 may block access. Credentials go to this private helper and Life360; no password is saved to disk.</p>'
    if not owner.busy and owner.stage != "sign-in":
        body += form("/life360/disconnect", "", "Disconnect Life360", csrf, True)
    return f'<section class="spaced"><div class="eyebrow">LIFE360 · OPTIONAL</div><h2>Check your Life360 profile</h2>{notice}{body}</section>'


def page(owner=None, csrf="", error="", life=None):
    busy = owner is not None and owner.busy
    refresh = '<meta http-equiv="refresh" content="3;url=/">' if busy or (life and life.busy) else ""
    message = error or (owner.message if owner else "")
    notice = f'<p role="alert" class="notice">{html.escape(message)}</p>' if message else ""
    if owner is None:
        title = "Open your helper"
        body = '<p>Enter the helper key you generated in Render.</p>' + form("/login",
            '<label>Helper key<input name="key" type="password" autocomplete="current-password" required maxlength="256"></label>',
            "Continue")
        body += '<p class="muted">Find it in Render → your service → Environment → SHIFT_ADMIN_KEY. This is not your Apple password.</p>'
    elif busy:
        title, body = "Connecting…", '<p>Finishing your Apple step. This page will update automatically.</p>'
    elif owner.stage == "code":
        title = "Check your Apple device"
        body = '<p>Enter the verification code Apple sent you.</p>' + form("/apple/verify",
            '<label>Verification code<input name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" maxlength="6" required></label>',
            "Verify", csrf)
    elif owner.stage == "device":
        title = "Choose your iPhone"
        options = "".join(f'<option value="{i}">{html.escape(name)}</option>' for i, name in enumerate(owner.devices))
        body = '<p>Select your own iPhone from Find My Devices.</p>' + form("/apple/select",
            f'<label>Device<select name="device">{options}</select></label>', "Use this iPhone", csrf)
    elif owner.stage == "ready":
        title = "Your helper is ready"
        body = (f'<p class="device">{html.escape(owner.target)}</p>'
                '<a class="button" href="/pairing">Download setup file</a>'
                '<p>In <strong>Shift 2.3.2 or later</strong>, open Settings → Find My checks → Cloud helper → Connect your helper. Enter this website and your helper key, or import the downloaded setup file. Older Shift versions can still import this file.</p>'
                '<p class="muted">Then start spoofing and enable checks in Shift. Ready means the helper is connected; only Shift can show whether a recent location matches. This checks Devices, not People.</p>')
    else:
        title = "Connect your Apple Account"
        body = '<p>Sign in to check your own iPhone in Find My Devices.</p>' + form("/apple/login",
            '<label>Apple Account email<input name="email" type="email" autocomplete="username" maxlength="254" required></label>'
            '<label>Apple Account password<input name="password" type="password" autocomplete="current-password" maxlength="1024" required></label>',
            "Sign in to Apple", csrf)
        body += '<p class="muted">This is your private Shift helper, not an Apple website. It uses an unofficial Apple connection. Credentials go to your helper and Apple; the password is not saved to disk. Sign in again after a server restart.</p>'
    if owner and not busy:
        if owner.stage != "sign-in":
            body += form("/apple/disconnect", "", "Disconnect Apple" if owner.stage == "ready" else "Start over", csrf, True)
        body += form("/logout", "", "Lock this page", csrf, True)
    extra = life360_panel(life, csrf) if owner and life else ""
    if owner:
        extra += '<section class="spaced"><h2>Connect Shift</h2><a class="button" href="/pairing">Download setup file</a><p>Connect either service above, then use Settings → Find My &amp; Life360 → Cloud helper in Shift 2.5.3 or later.</p><p class="muted">For optional free uptime pings, use cron-job.org with this website’s /healthz address every five minutes. No keys, passwords, headers or request body. Pings do not check locations or keep phone monitoring alive.</p></section>'
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">{refresh}<title>Shift · Cloud checks</title><link rel="stylesheet" href="/style.css"></head><body><main><header><span class="brand">Shift</span><span class="muted">by N3mo Studio</span></header><section><div class="eyebrow">FIND MY IPHONE · DEVICES</div><h1>{title}</h1>{notice}{body}</section>{extra}<footer>Your helper checks locations. It does not control spoofing.</footer></main></body></html>'''


STYLE = """.spaced{margin-top:20px}input.consent{width:auto;display:inline;min-height:24px}*{box-sizing:border-box}html{color-scheme:light dark}body{margin:0;background:var(--canvas);color:var(--ink);font:17px/1.6 system-ui,sans-serif;min-height:100dvh;--canvas:#f5f3f8;--surface:#fff;--ink:#201a2b;--secondary:#625b6d;--accent:#6336c5;--on-accent:#fff;--border:#d3cbdc}main{max-width:560px;margin:auto;padding:40px 20px}header{display:flex;align-items:baseline;flex-wrap:wrap;gap:12px;margin:0 4px 28px}.brand{font-size:34px;font-weight:750;letter-spacing:-1.5px}.muted,footer{color:var(--secondary);font-size:15px}section{background:var(--surface);border:1px solid var(--border);border-radius:24px;padding:28px}h1{font-size:30px;line-height:1.2;letter-spacing:-.7px;margin:12px 0 18px;overflow-wrap:anywhere}.eyebrow{font-size:13px;font-weight:650;letter-spacing:1.5px;color:var(--accent)}label{display:block;font-size:16px;font-weight:600;margin:18px 0 8px}input,select{display:block;width:100%;min-height:48px;border:1px solid var(--border);border-radius:12px;background:var(--canvas);color:var(--ink);font:inherit;padding:12px;margin-top:7px}button,.button{display:block;width:100%;border:0;border-radius:14px;background:var(--accent);color:var(--on-accent);text-align:center;text-decoration:none;font:inherit;font-weight:650;padding:14px;margin-top:20px;cursor:pointer;min-height:48px}button.secondary{background:transparent;color:var(--accent);border:1px solid var(--border);margin-top:12px}a:focus-visible,button:focus-visible,input:focus-visible,select:focus-visible{outline:3px solid var(--accent);outline-offset:4px}.notice{padding:14px;border-radius:12px;background:var(--canvas);border-left:4px solid var(--accent)}.device{font-weight:600}footer{text-align:center;margin-top:22px}@media(prefers-color-scheme:dark){body{--canvas:#111015;--surface:#201e26;--ink:#f5f3f8;--secondary:#bdb5c9;--accent:#c5aeff;--on-accent:#1d1136;--border:#51475f}}@media(max-width:360px){main{padding:24px 12px}section{padding:20px}}"""


def make_render_app(config, connector=None, store=None, interval=60, refresh_wait=4, life_connector=None, life_store=None):
    store = store or Store()
    owner = Owner(connector or WebApple(), store)
    life_store = life_store or Store(clock=store.clock)
    life = Owner(life_connector or WebLife360(), life_store, "life360")
    sessions = {}
    key_limit, apple_limit, check_limit = Limit(10, 60), Limit(6, 300), Limit(1, 1)
    life_limit = Limit(6, 300)
    refresh_task = None
    last_refresh = float("-inf")
    life_refresh = None
    last_life_refresh = float("-inf")
    closing = False

    def refresh_due():
        nonlocal refresh_task, last_refresh
        sid = store.polling_id()
        if closing or not sid or owner.busy:
            return None
        if refresh_task is not None and not refresh_task.done():
            return refresh_task
        if time.monotonic() - last_refresh < interval:
            return None
        last_refresh = time.monotonic()
        refresh_task = asyncio.create_task(owner.fetch(sid))
        return refresh_task

    def life_due():
        nonlocal life_refresh, last_life_refresh
        sid = life_store.polling_id()
        if closing or not sid or life.busy:
            return None
        if life_refresh is not None and not life_refresh.done():
            return life_refresh
        if time.monotonic() - last_life_refresh < interval:
            return None
        last_life_refresh = time.monotonic()
        life_refresh = asyncio.create_task(life.fetch(sid))
        return life_refresh

    def admin(request):
        now = time.monotonic()
        for key in list(sessions):
            if now >= sessions[key]["until"]:
                del sessions[key]
        value = sessions.get(request.cookies.get(COOKIE, ""))
        if value is None:
            raise web.HTTPUnauthorized(text="Unlock the helper page first.")
        return value

    @web.middleware
    async def boundary(request, handler):
        try:
            if request.path != "/healthz" and request.host != urlsplit(config.origin).hostname:
                raise web.HTTPBadRequest(text="Use the helper's public address.")
            if request.method == "POST" and not request.path.startswith("/v1/"):
                if request.headers.get("Origin") != config.origin:
                    raise web.HTTPForbidden(text="Open this form on your own helper page.")
                if request.content_type != "application/x-www-form-urlencoded":
                    raise web.HTTPBadRequest(text="Use the helper form.")
                async with asyncio.timeout(5):
                    data = await request.post()
                if request.path != "/login":
                    state = admin(request)
                    if not hmac.compare_digest(str(data.get("csrf", "")).encode(), state["csrf"].encode()):
                        raise web.HTTPForbidden(text="Reload the page and try again.")
            response = await handler(request)
        except web.HTTPException as error:
            response = error
        except Exception:
            response = web.Response(status=500, text="Helper unavailable. Reload the page and try again.")
        response.headers.update({"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            # no-referrer makes native form POSTs send Origin: null, which our
            # strict origin check correctly rejects. Keep same-site forms usable
            # while withholding referrer information from other sites.
            "Referrer-Policy": "same-origin", "X-Frame-Options": "DENY",
            "Content-Security-Policy": "default-src 'none'; style-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
            "Strict-Transport-Security": "max-age=31536000"})
        if isinstance(response, web.HTTPException):
            raise response
        return response

    app = web.Application(middlewares=[boundary], client_max_size=512*1024)

    async def index(request):
        try:
            state = admin(request)
        except web.HTTPUnauthorized:
            return web.Response(text=page(), content_type="text/html")
        return web.Response(text=page(owner, state["csrf"], life=life), content_type="text/html")

    async def login(request):
        if not key_limit.take():
            raise web.HTTPTooManyRequests(text="Too many attempts. Wait a minute and try again.")
        key = str((await request.post()).get("key", ""))
        if not hmac.compare_digest(key.encode(), config.admin_key.encode()):
            return web.Response(status=401, text=page(error="That helper key was not accepted."), content_type="text/html")
        sid = secrets.token_urlsafe(32)
        if len(sessions) >= 8:
            del sessions[next(iter(sessions))]
        sessions[sid] = {"csrf": secrets.token_urlsafe(32), "until": time.monotonic() + 12*3600}
        response = web.HTTPSeeOther("/")
        response.set_cookie(COOKIE, sid, secure=True, httponly=True, samesite="Strict", path="/", max_age=12*3600)
        return response

    async def logout(request):
        sessions.pop(request.cookies.get(COOKIE, ""), None)
        response = web.HTTPSeeOther("/")
        response.del_cookie(COOKIE, secure=True, httponly=True, samesite="Strict", path="/")
        return response

    async def apple(request):
        admin(request)
        data = await request.post()
        action = request.match_info["action"]
        if owner.busy:
            raise web.HTTPConflict(text="A step is already running. Wait for it to finish.")
        if action == "disconnect":
            owner.start("close")
        elif action in ("login", "verify"):
            if not apple_limit.take():
                raise web.HTTPTooManyRequests(text="Too many Apple attempts. Wait five minutes before trying again.")
            if action == "login":
                email, password = str(data.get("email", "")).strip(), str(data.get("password", ""))
                if not (3 <= len(email) <= 254 and "@" in email and 1 <= len(password) <= 1024):
                    raise web.HTTPBadRequest(text="Enter your Apple email and password.")
                owner.start("login", email, password)
            else:
                code = str(data.get("code", ""))
                if owner.stage != "code" or not re.fullmatch(r"[0-9]{6}", code):
                    raise web.HTTPBadRequest(text="Complete sign-in, then enter Apple's six-digit code.")
                owner.start("verify", code)
        elif action == "select":
            choice = str(data.get("device", ""))
            if owner.stage != "device" or not choice.isascii() or not choice.isdigit() or len(choice) > 4:
                raise web.HTTPBadRequest(text="Choose a listed device.")
            index = int(choice)
            if not 0 <= index < len(owner.devices):
                raise web.HTTPBadRequest(text="Choose a listed device.")
            owner.start("select", index)
        else:
            raise web.HTTPNotFound()
        return web.HTTPSeeOther("/")

    async def life_action(request):
        admin(request)
        data = await request.post()
        action = request.match_info["action"]
        if life.busy:
            raise web.HTTPConflict(text="A Life360 step is running. Wait for it to finish.")
        if action == "disconnect":
            life.start("close")
        elif action == "login":
            if not life_limit.take():
                raise web.HTTPTooManyRequests(text="Too many Life360 attempts. Wait five minutes and try again.")
            username, password = str(data.get("username", "")).strip(), str(data.get("password", ""))
            if data.get("consent") != "yes":
                raise web.HTTPBadRequest(text="Confirm permission to use the observer account for your own profile.")
            if not (3 <= len(username) <= 254 and 1 <= len(password) <= 1024):
                raise web.HTTPBadRequest(text="Enter the observer email or phone and password.")
            life.start("login", username, password)
        elif action in ("circle", "select"):
            choice = str(data.get("choice", ""))
            expected = "circle" if action == "circle" else "member"
            if (life.stage != expected or not choice.isascii() or not choice.isdigit()
                    or len(choice) > 4 or not 0 <= int(choice) < len(life.devices)):
                raise web.HTTPBadRequest(text="Choose one of the listed Circles or your own profile.")
            life.start(action, int(choice))
        else:
            raise web.HTTPNotFound()
        return web.HTTPSeeOther("/")

    async def pairing(request):
        admin(request)
        if not any(not o.busy and o.stage == "ready" for o in (owner, life)):
            raise web.HTTPConflict(text="Connect Apple or Life360 and choose your own device/profile first.")
        return web.Response(text=json.dumps(config.pairing, indent=2), content_type="application/json",
            headers={"Content-Disposition": 'attachment; filename="ShiftFindMyPairing.json"'})

    def phone(request):
        supplied = request.headers.get("Authorization", "").encode()
        if not hmac.compare_digest(supplied, ("Bearer " + config.phone_token).encode()):
            raise web.HTTPUnauthorized(text="Import your helper setup file in Shift.")

    async def check(request):
        phone(request)
        if not check_limit.take():
            raise web.HTTPTooManyRequests(text="Wait before checking again.")
        try:
            async with asyncio.timeout(5):
                data = await request.json()
            validate_request(data, store.clock())
            providers = data.get("providers", ["findmy-device"])
            if (not isinstance(providers, list) or len(providers) > 2 or
                    any(p not in ("findmy-device", "life360") for p in providers) or len(set(providers)) != len(providers)):
                raise ValueError("Invalid providers")
            # Each provider owns its report/auth state. One expired login must not
            # stop the other. Legacy clients only activate Apple polling.
            store.update(dict(data, active=data["active"] and "findmy-device" in providers))
            life_store.update(dict(data, active=data["active"] and "life360" in providers))
        except RuntimeError:
            raise web.HTTPConflict(text="Session replaced; restart checks.")
        except (ValueError, TypeError, KeyError, AttributeError, TimeoutError):
            raise web.HTTPBadRequest(text="Invalid check or clock.")
        # The old path replied before the polling loop fetched Apple's report,
        # leaving the phone one check behind. Share one rate-limited refresh with
        # the poller and briefly wait for it without cancelling a slow Apple call.
        pending = {task for task in (refresh_due(), life_due()) if task is not None}
        if pending:
            await asyncio.wait(pending, timeout=refresh_wait)
        result = store.snapshot()
        secondary = life_store.snapshot()
        result["life360"] = {k: secondary[k] for k in ("status", "report")}
        return web.json_response(result)

    async def status(request):
        phone(request)
        # Connection testing never polls Apple, shares points, or starts a lease.
        state = "busy" if owner.busy else "ready" if owner.stage == "ready" else "sign-in"
        secondary = "busy" if life.busy else "ready" if life.stage == "ready" else "sign-in"
        return web.json_response({"version": 1, "status": state, "life360": secondary})

    async def end(request):
        phone(request)
        store.close(request.match_info["sid"])
        life_store.close(request.match_info["sid"])
        return web.Response(status=204)

    async def health(_):
        # Uptime pings must never poll Apple, extend a phone lease, or imply a match.
        return web.Response(text="ok")

    async def style(_):
        return web.Response(text=STYLE, content_type="text/css")

    async def poll():
        while True:
            refresh_due()
            life_due()
            await asyncio.sleep(1)

    async def lifespan(_):
        nonlocal closing
        task = asyncio.create_task(poll())
        yield
        closing = True
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task
        # Let any outstanding bounded Apple request finish before closing its session.
        if refresh_task:
            with suppress(Exception):
                await asyncio.shield(refresh_task)
        if owner.job:
            with suppress(Exception):
                await asyncio.shield(owner.job)
        async with owner.lock:
            with suppress(Exception):
                await asyncio.to_thread(owner.connector.close)
        if life_refresh:
            with suppress(Exception):
                await asyncio.shield(life_refresh)
        if life.job:
            with suppress(Exception):
                await asyncio.shield(life.job)
        async with life.lock:
            with suppress(Exception):
                await life.call("close")
        sessions.clear()

    app.cleanup_ctx.append(lifespan)
    app.router.add_get("/", index)
    app.router.add_get("/style.css", style)
    app.router.add_get("/healthz", health)
    app.router.add_post("/login", login)
    app.router.add_post("/logout", logout)
    app.router.add_post("/apple/{action}", apple)
    app.router.add_post("/life360/{action}", life_action)
    app.router.add_get("/pairing", pairing)
    app.router.add_post("/v1/check", check)
    app.router.add_get("/v1/status", status)
    app.router.add_delete("/v1/session/{sid}", end)
    return app


def main():
    # Libraries can include Apple response bodies in logs. Never log requests/secrets.
    logging.disable(logging.CRITICAL)
    os.umask(0o077)
    try:
        config = Config(os.environ.get("RENDER_EXTERNAL_URL", "").rstrip("/"),
                        os.environ.get("SHIFT_ADMIN_KEY", ""))
        port = int(os.environ.get("PORT", "10000"))
        if not 1024 <= port <= 65535:
            raise ValueError("PORT must be an unprivileged port")
    except ValueError as error:
        print(str(error))  # Fixed setup errors only; never include environment values.
        raise SystemExit(1)
    print("Shift helper ready. Open the service HTTPS address to connect Apple. Health checks do not confirm a location.")
    web.run_app(make_render_app(config), host="0.0.0.0", port=port,
                print=None, access_log=None, shutdown_timeout=90,
                max_line_size=4096, max_field_size=4096)


if __name__ == "__main__":
    main()
