# Location verification and free setup options

Reviewed against the 2.5.2 source on 23 October 2026. This is a capability map and
proposal, not a claim that every external service was tested on a phone.

| Evidence | What it confirms | Current surface |
| --- | --- | --- |
| Command accepted | The simulation connection accepted Shift's command | App, Live Activity, Dynamic Island |
| This iPhone | A recent Core Location result delivered to Shift agreed with the sent point | In-app checks |
| Find My Devices | A fresh Apple device report agreed with Shift's point at that report's timestamp | App and Dynamic Island, using cloud or Windows helper |
| Find My People | Separate service meaning; Devices is not proof of what a person sees | No current People connector; unavailable must remain unavailable |
| Life360 | The Windows helper reads the selected member's report using an authorized observer account and compares its timestamp/location | In-app service checks; not yet sent to Dynamic Island |

The existing Life360 adapter uses the unofficial Python `life360` library. Its
setup asks for a separate consenting observer account because using the phone's
own account can interfere with its login. It makes read-only requests; it cannot
force a fresh service location. External adapters may be blocked or need sign-in.

## Free setup today

Both helper choices remain supported. If you already use the cloud helper, keep
Settings → Find My checks → Cloud helper selected; Windows is an alternative,
not a required replacement. The cloud helper can send Find My Devices evidence
to Dynamic Island while the laptop is off. No deployment or account changes are
part of this app update.

Use Settings → Find My checks → Windows helper on an already-owned, awake Windows
computer on the same Wi-Fi. Choose Find My Devices and/or Life360 during helper
setup and import its pairing file. There is no Shift subscription or cloud hosting
bill; the computer still uses power and must remain reachable. See
[Windows setup](../Companion/README.txt). A Life360-only helper currently has no
Find My evidence to show on the Island.

The cloud helper supports Find My Devices when the laptop is off. Render's free
service sleeps after 15 minutes without inbound traffic, can take about a minute
to wake, and does not offer a persistent disk; restarts lose local state. Treat it
as a hobby/test option, not an always-available verifier. See
[Render's free-service limits](https://render.com/docs/free) and
[cloud setup](../CloudFindMy/RENDER-SETUP.txt).

## Proposed next improvements — not implemented in build 50

1. Add separate Find My / Life360 rows to expanded Dynamic Island and session
   details, with a source name, Match/Different/Old/Unavailable state and actual
   service location age. A compact summary should prioritize a mismatch or stale
   source rather than imply that a single green check covers every service.
2. Keep service location time separate from helper reply time. Preserve existing
   freshness expiry, pending/sign-in/blocked states and bounded polling; a reply
   from the helper is not a fresh Apple/Life360 report.
3. Simplify Windows setup with a single readiness screen: helper reachable,
   provider signed in, target selected, report fresh. Provide one manual retry
   after backoff, without continuous aggressive refreshes.
   Give the cloud helper the same clarity, separating wake-up/reconnect from
   expired Apple sign-in and an old Apple report, with timestamps for each.
4. Consider a personally owned always-on home helper with authenticated private
   remote access for use away from Wi-Fi. That needs a separate networking/security
   implementation and testing; it is not a feature of the current LAN helper.

Apple documents that Live Activities cannot fetch the network or receive location
updates themselves. Updates come from the app or ActivityKit pushes. An activity
lasts at most eight hours in Dynamic Island, so a 24-hour stop cannot promise one
uninterrupted 24-hour Island display. Background execution remains system-controlled.
[Apple ActivityKit constraints](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities).

A meaningful device test compares Shift's labeled service evidence with the
corresponding authorized observer view, including timestamps, then repeats with
old reports, loss of Wi-Fi, app backgrounding and expired sign-in. Unknown evidence
must never become a claimed match.
