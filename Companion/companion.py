"""Optional foreground Shift helper. No account writes or remote control."""
from __future__ import annotations
import argparse
import asyncio
from datetime import datetime, timedelta, timezone
import getpass
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import logging
import os
from pathlib import Path
import secrets
import ssl
import socket
import tempfile
import threading
import time

from reports import apple_report, life360_report, missing, failure_state


def private_ipv4(value):
    address = ipaddress.IPv4Address(value)
    if not any(address in ipaddress.IPv4Network(net) for net in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")):
        raise ValueError("Use this laptop's Wi-Fi IPv4 address, such as 192.168.1.25.")
    return str(address)


def choose_host(explicit=None, ask=input):
    if explicit:
        return private_ipv4(explicit)
    detected = None
    try:
        # UDP connect selects the default route; no data is transmitted.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("1.1.1.1", 9))
            detected = private_ipv4(probe.getsockname()[0])
    except (OSError, ValueError):
        pass
    prompt = f"Laptop address: {detected}. Press Enter to use it, or type another: " if detected else "Laptop Wi-Fi IPv4 address: "
    return private_ipv4(ask(prompt).strip() or detected or "")


def choose(title, entries, label):
    if not entries:
        raise RuntimeError("No selectable items were returned.")
    print(title)
    for i, entry in enumerate(entries, 1):
        # Names only, never account tokens or full raw service responses.
        print(f"  {i}. {str(label(entry))[:120]}")
    while True:
        value = input("Choose a number (or q to cancel): ").strip()
        if value.lower() == "q":
            raise KeyboardInterrupt
        try:
            number = int(value)
            if 1 <= number <= len(entries):
                return entries[number - 1]
        except ValueError:
            pass
        print("Choose one of the listed numbers.")


class AppleConnector:
    provider = "findmy-device"

    def __init__(self, cookies):
        from pyicloud import PyiCloudService
        from requests.adapters import HTTPAdapter
        class TimedAdapter(HTTPAdapter):
            def send(self, request, **kwargs):
                if kwargs.get("timeout") is None:
                    kwargs["timeout"] = (10, 20)
                return super().send(request, **kwargs)
        username = input("Apple Account email (entered on this computer only): ").strip()
        password = getpass.getpass("Apple Account password: ")
        self.api = PyiCloudService(username, password, cookie_directory=str(cookies),
                                   with_family=False, accept_terms=False, refresh_interval=86400,
                                   authenticate=False)
        del password
        self.api.session.mount("https://", TimedAdapter())
        self.api.authenticate()
        if self.api.requires_2fa:
            if self.api.security_key_names:
                device = choose("Choose your connected security key:", list(self.api.fido2_devices), str)
                self.api.confirm_security_key(device)
            else:
                self.api.request_2fa_code()
                if not self.api.validate_2fa_code(getpass.getpass("Apple verification code: ")):
                    raise RuntimeError("Apple didn't accept the code. Restart to try again.")
            if not self.api.is_trusted_session and not self.api.trust_session():
                raise RuntimeError("Apple didn't trust this session. Restart to try again.")
        elif self.api.requires_2sa:
            device = choose("Choose your trusted device:", self.api.trusted_devices,
                            lambda d: d.get("deviceName") or d.get("phoneNumber", "Trusted device"))
            if not self.api.send_verification_code(device):
                raise RuntimeError("Apple couldn't send a code.")
            if not self.api.validate_verification_code(device, getpass.getpass("Apple verification code: ")):
                raise RuntimeError("Apple didn't accept the code.")
        self.manager = self.api.devices
        entries = list(self.manager.devices.items())
        selected = choose("Select YOUR iPhone from Find My Devices:", entries,
                          lambda pair: pair[1].status().get("name", "Unnamed device"))
        self.device_id = selected[0]
        self.target = str(selected[1].status().get("name") or "Selected iPhone")[:120]
        print("This checks Devices, not the People location shared with friends.")

    def fetch(self):
        # Public read API. Never call play_sound, lost_device, erase_device or messages.
        self.manager.refresh(locate=True)
        device = self.manager.devices.get(self.device_id)
        if device is None:
            return missing(self.provider, self.target)
        return apple_report(self.target, device.location)

    def close(self):
        self.manager.stop_event.set()
        self.api.session.close()


class Life360Connector:
    provider = "life360"

    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.session = None
        print("Use a separate consenting Circle member's account, with permission to view YOUR phone.")
        print("Using your phone's own account here can sign it out and interfere with the test.")
        if input("Do you have that authorized observer account? (yes/no): ").strip().lower() != "yes":
            raise RuntimeError("Life360 setup cancelled.")
        username = input("Observer email or phone number: ").strip()
        password = getpass.getpass("Observer password: ")
        try:
            self.loop.run_until_complete(self.login(username, password))
            circles = self.loop.run_until_complete(self.api.get_circles())
            circle = choose("Choose the Circle containing your phone:", circles, lambda c: c.get("name", "Circle"))
            members = self.loop.run_until_complete(self.api.get_circle_members(circle["id"]))
            member = choose("Select YOUR profile to check:", members,
                            lambda m: " ".join(str(m.get(k, "")) for k in ("firstName", "lastName")).strip())
            self.cid, self.mid = circle["id"], member["id"]
            self.target = (" ".join(str(member.get(k, "")) for k in ("firstName", "lastName")).strip() or "Selected profile")[:120]
        except BaseException:
            self.close()
            raise
        finally:
            del password

    async def login(self, username, password):
        from aiohttp import ClientSession, ClientTimeout
        from life360 import Life360
        self.session = ClientSession(timeout=ClientTimeout(total=20))
        self.api = Life360(self.session, max_retries=0, verbosity=0)
        await self.api.login_by_username(username, password)

    def fetch(self):
        # Read-only: no request_location_update calls or Circle changes.
        member = self.loop.run_until_complete(self.api.get_circle_member(self.cid, self.mid))
        return life360_report(self.target, member)

    def close(self):
        if not self.loop.is_closed():
            if self.session:
                self.loop.run_until_complete(self.session.close())
            self.loop.close()


class ProviderWorker:
    """One worker per service; blocked/auth failures stop polling until restart."""
    def __init__(self, connector, interval=60):
        self.connector = connector
        self.interval = max(60, interval)
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.report = missing(connector.provider, connector.target)
        self.thread = threading.Thread(target=self.run, daemon=True)

    def snapshot(self):
        with self.lock:
            return self.report

    def once(self):
        with self.lock:
            self.report = missing(self.connector.provider, self.connector.target)
        try:
            report = self.connector.fetch()
        except Exception as error:
            state = failure_state(error)
            report = missing(self.connector.provider, self.connector.target, state)
        with self.lock:
            self.report = report
        return report.state not in ("sign-in", "blocked")

    def run(self):
        try:
            while not self.stop.is_set():
                if not self.once():
                    print(f"{self.connector.provider}: sign-in or service access needs attention. Polling stopped; restart after resolving it.")
                    break
                if self.stop.wait(self.interval):
                    break
        finally:
            self.connector.close()


def handler_for(token, workers):
    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def log_message(self, *_):
            pass  # Never log headers, names or coordinates.

        def do_GET(self):
            provided = self.headers.get("Authorization", "")
            if not hmac.compare_digest(provided.encode("utf-8"), f"Bearer {token}".encode("ascii")):
                self.send_error(401)
                return
            if self.path != "/reports":
                self.send_error(404)
                return
            reports = [worker.snapshot().json() for worker in workers]
            reports.append(missing("findmy-person", "People check unavailable on this Windows companion").json())
            payload = json.dumps({"version": 1, "reports": reports}, allow_nan=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
    return Handler


def certificate(folder, host):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Shift local helper")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=5))
            .not_valid_after(now + timedelta(days=365))
            .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.IPv4Address(host))]), critical=False)
            .sign(key, hashes.SHA256()))
    key_file, cert_file = folder / "key.pem", folder / "cert.pem"
    key_file.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    cert_file.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    fingerprint = hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()
    return cert_file, key_file, fingerprint


def run(args):
    # Library exceptions/logging can include sensitive API responses.
    logging.disable(logging.CRITICAL)
    print("Shift Windows helper\nKeep this window open while computer checks are enabled.")
    host = choose_host(args.host)
    data_dir = Path(os.getenv("LOCALAPPDATA", str(Path.home()))) / "ShiftCompanion"
    data_dir.mkdir(parents=True, exist_ok=True)
    workers = []
    with tempfile.TemporaryDirectory(prefix="session-", dir=data_dir) as temp:
        folder = Path(temp)
        from identity import load_or_create
        try:
            token, cert, key, fingerprint, reused = load_or_create(
                data_dir / "identity.dat", host, folder, certificate, reset=args.reset_pairing, port=args.port)
        except (ValueError, OSError, KeyError, TypeError):
            print("Could not open this Windows account's saved pairing. To replace it, run the helper with --reset-pairing and import its new setup file.")
            return
        for name, factory in (("Find My Devices", lambda: AppleConnector(folder / "apple")), ("Life360", Life360Connector)):
            if input(f"Set up {name}? (yes/no): ").strip().lower() == "yes":
                try:
                    workers.append(ProviderWorker(factory()))
                except Exception as error:
                    print(f"{name} setup did not complete ({type(error).__name__}). Check sign-in in the official service; restart to retry. No report confirmed.")
        if not workers:
            print("No service connected. Nothing started.")
            return
        server = ThreadingHTTPServer((host, args.port), handler_for(token, workers))
        server.daemon_threads = True
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        pairing = Path(args.pairing).resolve()
        pairing.write_text(json.dumps({"version": 1, "endpoint": f"https://{host}:{args.port}", "token": token,
                                       "certificateSHA256": fingerprint}, indent=2), encoding="utf-8")
        print(f"Pairing file saved: {pairing}")
        print("Shift → Settings → Find My checks → Windows helper → Import setup file.")
        print("Existing pairing retained; no new import is needed on this network." if reused else "New pairing: send this file to your iPhone with LocalSend, then import it in Shift.")
        print("The file is a secret access key. Delete the transfer copy after pairing; don't put it on GitHub.")
        print("Allow Python on PRIVATE networks if Windows asks. Keep this window open. Ctrl+C stops checks.")
        print("Pairing survives restarts on the same address. A changed Wi-Fi address needs a new import.")
        print("Apple/Life360 passwords are not saved. Windows protects the saved pairing identity for your account.")
        print(f"Connection test in iPhone Safari: https://{host}:{args.port}/reports (401 means reachable).")
        for worker in workers:
            worker.thread.start()
        try:
            server.serve_forever(poll_interval=0.5)
        except KeyboardInterrupt:
            pass
        finally:
            server.server_close()
            for worker in workers:
                worker.stop.set()
            for worker in workers:
                worker.thread.join(timeout=25)
            # Remove only the exact pairing file produced by this run, and only
            # if its content is still our token (never a replacement file).
            try:
                if json.loads(pairing.read_text(encoding="utf-8")).get("token") == token:
                    pairing.unlink()
            except (OSError, ValueError):
                pass
            print("Checks stopped. Cached reports in Shift expire automatically.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Experimental Shift Windows helper")
    parser.add_argument("--host", help="This laptop's private Wi-Fi IPv4 address")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--pairing", default="ShiftCompanionPairing.json")
    parser.add_argument("--reset-pairing", action="store_true", help="Replace this computer's pairing key and require a new import")
    arguments = parser.parse_args()
    if not 1 <= arguments.port <= 65535:
        parser.error("Port must be 1–65535")
    try:
        run(arguments)
    except KeyboardInterrupt:
        print("Cancelled.")
    except Exception as failure:
        print(f"Companion stopped ({type(failure).__name__}). Check your Wi-Fi address, dependencies, and service sign-in. No report confirmed.")
        raise SystemExit(1)
