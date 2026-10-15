"""Validate provider evidence without turning request time into location time."""
from __future__ import annotations
from dataclasses import asdict, dataclass
import math
import time


@dataclass(frozen=True)
class Report:
    provider: str
    target: str
    state: str
    latitude: float | None = None
    longitude: float | None = None
    locatedAt: float | None = None
    accuracy: float | None = None
    fetchedAt: float = 0

    def json(self):
        return asdict(self)


def missing(provider, target, state="unavailable", now=None):
    return Report(provider, str(target)[:120], state, fetchedAt=time.time() if now is None else now)


def number(value):
    if isinstance(value, bool):
        raise ValueError("Boolean is not a measurement")
    value = float(value)
    if not math.isfinite(value):
        raise ValueError("Non-finite measurement")
    return value


def location(provider, target, raw, *, now, milliseconds=False, feet=False):
    try:
        lat, lon = number(raw["latitude"]), number(raw["longitude"])
        timestamp = number(raw["timeStamp" if milliseconds else "timestamp"])
        timestamp /= 1000 if milliseconds else 1
        accuracy = number(raw["horizontalAccuracy" if milliseconds else "accuracy"])
        accuracy *= 0.3048 if feet else 1
        if not (-90 <= lat <= 90 and -180 <= lon <= 180 and 0 <= accuracy and 0 < timestamp <= now):
            raise ValueError("Invalid or future measurement")
        state = "old" if now - timestamp > 90 or raw.get("isOld") is True else "ok"
        return Report(provider, str(target)[:120], state, lat, lon, timestamp, accuracy, now)
    except (KeyError, ValueError, TypeError, OverflowError):
        return missing(provider, target, now=now)


def apple_report(target, raw, *, now=None):
    now = time.time() if now is None else now
    if not isinstance(raw, dict):
        return missing("findmy-device", target, now=now)
    return location("findmy-device", target, raw, now=now, milliseconds=True)


def life360_report(target, member, *, now=None):
    now = time.time() if now is None else now
    if not isinstance(member, dict):
        return missing("life360", target, now=now)
    try:
        if int(member["features"]["shareLocation"]) != 1:
            return missing("life360", target, now=now)
        raw = member["location"]
        if not isinstance(raw, dict):
            return missing("life360", target, now=now)
        return location("life360", target, raw, now=now, feet=True)
    except (KeyError, TypeError, ValueError):
        return missing("life360", target, now=now)


def failure_state(error):
    """Never echo exception bodies, which may contain account details."""
    name = type(error).__name__.lower()
    if any(term in name for term in ("login", "auth", "password", "2fa", "2sa", "trusted")):
        return "sign-in"
    if any(term in name for term in ("ratelimit", "forbidden", "locked", "terms")):
        return "blocked"
    response = getattr(error, "response", None)
    code = getattr(error, "status", None) or getattr(response, "status_code", None) or getattr(error, "code", None)
    try:
        code = int(code)
    except (ValueError, TypeError):
        code = None
    if code in (401,):
        return "sign-in"
    if code in (403, 429):
        return "blocked"
    return "unavailable"
