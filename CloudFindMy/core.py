"""Single-owner, memory-only Find My check sessions. No Apple account writes."""
from __future__ import annotations
from dataclasses import dataclass
from collections import deque
import math
import time
import uuid


def measurement(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("Invalid measurement")
    return float(value)


def validate_request(data, now):
    if not isinstance(data, dict) or data.get("version") != 1:
        raise ValueError("Invalid request")
    session = str(uuid.UUID(data["sessionID"]))
    started, sent = measurement(data["startedAt"]), measurement(data["sentAt"])
    seq = data["sequence"]
    if type(seq) is not int or not 1 <= seq <= 2**53 or not 0 < started <= now + 5 or abs(sent - now) > 30:
        raise ValueError("Invalid clock or sequence")
    if type(data["active"]) is not bool:
        raise ValueError("Invalid activity")
    samples = data["samples"]
    if not isinstance(samples, list) or len(samples) > 2000:
        raise ValueError("Too many samples")
    previous = None
    for sample in samples:
        lat, lon, at = (measurement(sample[k]) for k in ("latitude", "longitude", "confirmedAt"))
        until = sample.get("validUntil")
        if until is not None:
            until = measurement(until)
        if not (-90 <= lat <= 90 and -180 <= lon <= 180 and max(started, now - 330) <= at <= now + 5):
            raise ValueError("Invalid sample")
        if until is not None and not at <= until <= now + 5:
            raise ValueError("Invalid interval")
        if previous and (at <= previous["confirmedAt"] or previous.get("validUntil") is None or previous["validUntil"] > at):
            raise ValueError("Overlapping or unordered history")
        previous = sample
    return session, started, seq


def verdict(report, history, now, active):
    if not active:
        return "paused"
    if not report:
        return "waiting"
    if report["state"] in ("sign-in", "blocked", "unavailable"):
        return report["state"]
    if report["state"] == "old":
        return "old"
    at, accuracy = report.get("locatedAt"), report.get("accuracy")
    if at is None or accuracy is None or accuracy > 100 or report.get("latitude") is None or report.get("longitude") is None:
        return "unavailable"
    if not 0 <= now - at <= 90 or not -5 <= now - report["fetchedAt"] <= 90:
        return "old"
    sample = next((s for s in reversed(history) if s["confirmedAt"] <= at), None)
    if not sample or at - sample["confirmedAt"] > 40 or (sample.get("validUntil") is not None and at >= sample["validUntil"]):
        return "waiting"
    r = math.pi / 180
    a = math.sin((report["latitude"] - sample["latitude"]) * r / 2)**2
    a += math.cos(sample["latitude"] * r) * math.cos(report["latitude"] * r) * math.sin((report["longitude"] - sample["longitude"]) * r / 2)**2
    metres = 6371000 * 2 * math.atan2(math.sqrt(min(1, a)), math.sqrt(max(0, 1-a)))
    return "match" if metres <= max(15, accuracy) else "different"


@dataclass
class CheckSession:
    id: str
    started: float
    sequence: int
    seen: float
    active: bool
    history: list
    closed: bool = False


class Store:
    """Only accessed on the event loop. Apple fetches run off-loop."""
    lease_seconds = 150

    def __init__(self, clock=time.time):
        self.clock = clock
        self.session = None
        self.report = None
        self.auth_state = None
        self.closed_ids = deque(maxlen=64)

    def expire(self):
        s = self.session
        if s and self.clock() - s.seen > self.lease_seconds:
            s.active = False
            s.history = []
            self.report = None

    def update(self, data):
        now = self.clock()
        sid, started, seq = validate_request(data, now)
        if sid in self.closed_ids:
            raise RuntimeError("Closed session")
        s = self.session
        if s and sid == s.id:
            if s.closed or seq <= s.sequence or started != s.started:
                raise RuntimeError("Obsolete request")
        else:
            if s and started <= s.started:
                raise RuntimeError("Obsolete session")
            self.report = None
        self.session = CheckSession(sid, started, seq, now, data["active"], data["samples"] if data["active"] else [])
        if not data["active"]:
            self.report = None
        return self.snapshot()

    def close(self, sid):
        # DELETE may arrive before an in-flight first POST.
        try:
            sid = str(uuid.UUID(sid))
        except ValueError:
            return
        if sid not in self.closed_ids:
            self.closed_ids.append(sid)
        if self.session and self.session.id == sid:
            self.session.closed = True
            self.session.active = False
            self.session.history = []
            self.report = None

    def polling_id(self):
        self.expire()
        s = self.session
        return s.id if s and s.active and not s.closed and not self.auth_state else None

    def publish(self, sid, report):
        # A late fetch cannot resurrect a stopped/expired/replaced session.
        if self.polling_id() == sid:
            self.report = report
            if report["state"] in ("sign-in", "blocked"):
                self.auth_state = report["state"]

    def snapshot(self):
        self.expire()
        s = self.session
        active = bool(s and s.active and not s.closed)
        status = self.auth_state if active and self.auth_state else verdict(self.report, s.history if s else [], self.clock(), active)
        return {"version": 1, "sessionID": s.id if s else None, "sequence": s.sequence if s else 0,
                "serverTime": self.clock(), "status": status, "report": self.report if active else None}
