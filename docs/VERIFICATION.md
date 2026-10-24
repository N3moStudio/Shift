# Location verification and free setup

Source capability map for **2.5.3 (51)**, 23 October 2026. External account access
and iPhone background behavior still require device acceptance tests.

| Evidence | What it confirms | Where it appears |
| --- | --- | --- |
| Command accepted | Developer connection accepted Shift's command | App and the existing Shift Live Activity |
| This iPhone | Core Location delivered a recent matching fix to Shift | In-app checks; not proof of another app |
| Find My iPhone | Fresh Find My **Devices** report matched the point sent at that report's time | Cloud or Windows helper; app, Lock Screen and Dynamic Island |
| Life360 | Selected profile's report matched the point sent at that report's time | Updated Render cloud helper or Windows helper; app, Lock Screen and Dynamic Island |
| Find My People | What a person sees in the People tab | No connector; Devices is not proof of People |

## One activity, independent evidence

There is **one Shift Live Activity**, with one Find My status and one Life360
status inside it. Expanded Dynamic Island and Lock Screen show source names and
location ages. Compact Island uses separately labeled cloud/profile icons;
it never combines both services into one green verdict.

Settings → **Find My & Life360 → Cloud helper**:
- **Check Find My iPhone / Check Life360** control provider polling. Life360 is
  off until enabled. One provider's expired login does not stop the other.
- **Show Find My iPhone status / Show Life360 status** control visibility in the
  existing Live Activity. The same settings are available in Live Activities.
- **Test connection** checks access and each provider's setup without sending
  points, fetching locations, or starting a monitoring lease.
- **Check now** requests current helper evidence, with provider reads limited to
  about once per minute. It cannot force either provider to refresh a location.

The existing v1 envelope now has an optional Life360 report. Old helpers remain
readable; Life360 asks for a helper update instead of borrowing Apple evidence.
The app never activates an old Apple-only helper for a Life360-only request.
Existing setup files and Keychain identities remain compatible. The Oracle
terminal helper remains Find My Devices only.

## Free Render setup and uptime pinger

Deploy the updated helper from `codex/shift-2.5.0` for this prerelease, using
[RENDER-SETUP.txt](../CloudFindMy/RENDER-SETUP.txt). Keep the service URL and
SHIFT_ADMIN_KEY to preserve pairing. Redeploys/restarts require provider sign-in
again. Apple uses your own account/iPhone; Life360 uses a separate consenting
observer account that already sees your own profile. Signing in with the phone's
Life360 account can interfere with its login. Both adapters are unofficial and
can be blocked; the helper does not bypass account protection.

The free pinger is **[cron-job.org](https://cron-job.org/en/faq/)**. Copy/share the
uptime URL from Cloud helper; configure GET `/healthz` every five minutes, with
no authentication, secret headers or request body. It returns only `ok`.
The FAQ describes free schedules as frequent as once per minute and a 30-second
request timeout. A first request can time out while Render wakes.

[Render's free plan](https://render.com/docs/free) sleeps after 15 minutes without
inbound traffic, usually needs about a minute to wake, has ephemeral storage,
and shares 750 free instance hours per workspace per month. Pings reduce idle
sleep but cannot prevent restarts, limits, sign-in expiry or outages. No paid
plan, push service, database or Shift subscription is required by this implementation.

Uptime pings **never poll Apple or Life360, upload points, extend the 150-second
phone lease, or prove a location match**. If the app stops updating, monitoring
expires and its point history is cleared. Location timestamps, reply timestamps,
accuracy, active-session evidence and independent freshness limits stay mandatory.

## Limits and device acceptance

[Apple's ActivityKit documentation](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
states that an activity cannot fetch the network or location itself. Shift must
be allowed to run to deliver local updates. There is no independent server-to-Island
push service in this build. Dynamic Island activities last at most eight hours;
a 24-hour stop does not promise an uninterrupted 24-hour Island display.

Compare each labeled status with the authorized observer view and timestamp.
Repeat with old reports, provider sign-out, server sleep, lost internet,
backgrounding, turning checks off, and each visibility switch. Unknown evidence
must never become a claimed match. See [the device checklist](TESTING-2.5.md).
