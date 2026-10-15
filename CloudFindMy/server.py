"""Private HTTPS prototype. Apple sign-in happens in the owner's SSH terminal."""
from __future__ import annotations
import argparse
import asyncio
from contextlib import suppress
from datetime import datetime, timedelta, timezone
import hashlib
import hmac
import ipaddress
import json
import logging
import os
from pathlib import Path
import secrets
import ssl
import sys
import tempfile
import time
from aiohttp import web

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Companion"))
from companion import AppleConnector
from reports import failure_state, missing
from core import Store


def make_app(token, connector, store=None, interval=60):
    store = store or Store()
    last_request = 0.0
    @web.middleware
    async def authorize(request, handler):
        nonlocal last_request
        supplied = request.headers.get("Authorization", "").encode("utf-8")
        if not hmac.compare_digest(supplied, ("Bearer " + token).encode("ascii")):
            raise web.HTTPUnauthorized(text="Pairing required")
        if request.method == "POST":
            now = time.monotonic()
            if now - last_request < 1:
                raise web.HTTPTooManyRequests(text="Wait before checking again")
            last_request = now
        response = await handler(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    app = web.Application(middlewares=[authorize], client_max_size=512*1024)
    async def check(request):
        try:
            async with asyncio.timeout(5):
                data = await request.json()
            result = store.update(data)
        except RuntimeError:
            raise web.HTTPConflict(text="Session replaced; restart checks")
        except (ValueError, TypeError, KeyError, AttributeError, TimeoutError):
            raise web.HTTPBadRequest(text="Invalid check or clock")
        return web.json_response(result)

    async def end(request):
        store.close(request.match_info["sid"])
        return web.Response(status=204)

    async def poll():
        last_poll = 0.0
        while True:
            sid = store.polling_id()
            if sid and time.monotonic() - last_poll >= interval:
                last_poll = time.monotonic()
                try:
                    report = (await asyncio.to_thread(connector.fetch)).json()
                except Exception as error:
                    report = missing("findmy-device", "Selected iPhone", failure_state(error)).json()
                store.publish(sid, report)
            await asyncio.sleep(1)

    async def lifespan(_):
        task = asyncio.create_task(poll())
        yield
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task

    app.cleanup_ctx.append(lifespan)
    app.router.add_post("/v1/check", check)
    app.router.add_delete("/v1/session/{sid}", end)
    return app


def initialize(folder, host, port):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    address = ipaddress.ip_address(host)
    if address.version != 4 or not address.is_global:
        raise ValueError("Use your cloud server's public IPv4 address")
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    folder.chmod(0o700)
    if any(folder.iterdir()):
        raise ValueError("Folder is not empty; existing pairing was not changed")
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Shift Find My helper")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now-timedelta(minutes=5))
        .not_valid_after(now+timedelta(days=365))
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(address)]), critical=False).sign(key, hashes.SHA256()))
    (folder/"key.pem").write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    (folder/"cert.pem").write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    link = {"version": 1, "kind": "shift-findmy-cloud", "endpoint": f"https://{host}:{port}",
        "token": secrets.token_hex(32), "certificateSHA256": hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()}
    (folder/"ShiftFindMyPairing.json").write_text(json.dumps(link, indent=2))
    (folder/"port.txt").write_text(str(port))
    for path in folder.iterdir():
        path.chmod(0o600)
    print("Private pairing created at " + str(folder/"ShiftFindMyPairing.json"))


def main():
    parser = argparse.ArgumentParser(description="Shift Find My Devices cloud prototype")
    parser.add_argument("command", choices=["init", "serve"])
    parser.add_argument("--data", type=Path, default=Path.home()/".local/share/shift-findmy")
    parser.add_argument("--host", help="Public IPv4, used only by init")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("Use an unprivileged port from 1024 to 65535")
    os.umask(0o077)
    logging.disable(logging.CRITICAL)  # Third-party errors can contain account responses.
    if args.command == "init":
        initialize(args.data, args.host, args.port)
        return
    pairing = json.loads((args.data/"ShiftFindMyPairing.json").read_text())
    port = int((args.data/"port.txt").read_text())
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.data/"cert.pem", args.data/"key.pem")
    print("Sign in to YOUR Apple Account here. Passwords are not written to disk.")
    print("Use a private tmux session so this stays running when your laptop disconnects.")
    # On Linux use a memory-backed temporary folder when available. No persistent Apple cookies.
    ram = "/dev/shm" if Path("/dev/shm").is_dir() else None
    with tempfile.TemporaryDirectory(prefix="shift-apple-", dir=ram) as cookies:
        connector = AppleConnector(Path(cookies))
        connector.manager.stop_event.set()  # Only our session-scoped worker may poll Apple.
        print("Ready. Import ShiftFindMyPairing.json in Shift > Settings > Experimental Features > Remote Find My > Set up Remote Find My.")
        print("Polling starts with an active paired Shift session and stops after 150 seconds without an update.")
        print("If Apple sign-in expires, reconnect to this terminal, stop with Ctrl+C, and run serve again.")
        try:
            web.run_app(make_app(pairing["token"], connector), host="0.0.0.0", port=port,
                ssl_context=context, print=None, access_log=None, handler_cancellation=True,
                shutdown_timeout=25, keepalive_timeout=10, max_line_size=4096, max_field_size=4096)
        finally:
            connector.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("Stopped.")
    except Exception as error:
        print(f"Helper stopped ({type(error).__name__}). Check setup or sign-in. No location confirmed.")
        raise SystemExit(1)
