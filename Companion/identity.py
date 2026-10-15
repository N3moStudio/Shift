"""Windows-user-bound helper identity. Apple passwords are never stored here."""
from __future__ import annotations
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import secrets


def _dpapi(data: bytes, *, decrypt: bool = False) -> bytes:
    if os.name != "nt":
        raise OSError("Persistent pairing requires Windows account protection")
    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]
    memory = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    source, destination = Blob(len(data), memory), Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    kernel.LocalFree.restype = ctypes.c_void_p
    function = crypt.CryptUnprotectData if decrypt else crypt.CryptProtectData
    function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                         ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    function.restype = wintypes.BOOL
    # CRYPTPROTECT_UI_FORBIDDEN, current Windows user scope (never LOCAL_MACHINE).
    if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(destination)):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return ctypes.string_at(destination.data, destination.size)
    finally:
        kernel.LocalFree(destination.data)


def protect(data): return _dpapi(data)
def unprotect(data): return _dpapi(data, decrypt=True)


def load_or_create(path: Path, host: str, folder: Path, make_certificate, *, reset=False, port=8765,
                   encode=protect, decode=unprotect):
    """Fail closed on unreadable identity; don't silently strand paired phones."""
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    from datetime import datetime, timedelta, timezone
    import hashlib
    record = None
    if path.exists() and not reset:
        if path.stat().st_size > 65536:
            raise ValueError("Saved helper identity is too large")
        record = json.loads(decode(path.read_bytes()))
        if record.get("version") != 1:
            raise ValueError("Unsupported helper identity")
        cert = x509.load_pem_x509_certificate(record["certificate"].encode())
        private_key = serialization.load_pem_private_key(record["key"].encode(), password=None)
        public_format = (serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        if cert.public_key().public_bytes(*public_format) != private_key.public_key().public_bytes(*public_format):
            raise ValueError("Helper identity key does not match")
        if record["host"] != host or record.get("port", 8765) != port or cert.not_valid_after_utc <= datetime.now(timezone.utc) + timedelta(days=1):
            record = None
        elif len(record.get("token", "")) != 64 or any(c not in "0123456789abcdef" for c in record["token"]):
            raise ValueError("Invalid saved helper key")
    reused = record is not None
    if record is None:
        cert_file, key_file, _ = make_certificate(folder, host)
        record = {"version": 1, "host": host, "port": port, "token": secrets.token_hex(32),
                  "certificate": cert_file.read_text(), "key": key_file.read_text()}
        sealed = encode(json.dumps(record).encode())
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(path.name + ".new")
        try:
            temporary.write_bytes(sealed)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    cert_file, key_file = folder / "cert.pem", folder / "key.pem"
    cert_file.write_text(record["certificate"])
    key_file.write_text(record["key"])
    cert = x509.load_pem_x509_certificate(record["certificate"].encode())
    fingerprint = hashlib.sha256(cert.public_bytes(serialization.Encoding.DER)).hexdigest()
    return record["token"], cert_file, key_file, fingerprint, reused
