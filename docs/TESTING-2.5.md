# Shift 2.5.x test builds

These are test builds; any GitHub release is marked prerelease. A successful IPA build is
separate from testing on a signed iPhone. Record both results before release.

## 2.5.2 (50): waits through 24 hours

1. Create/open a route with a stop. Tap its clock/wait row in the numbered timeline. Also check Edit place → Wait here and Add stop → Wait here; all three use the same Hours / Minutes / Seconds controls.
2. Choose 0:00:01, 0:00:15, 0:00:59, 0:01:30, 1:00:01, 23:59:59 and 24:00:00. At 24 hours, minutes/seconds become zero and are disabled. Changing hours below 24 makes them available again.
3. Try every quick preset. Cancel and swipe-dismiss must keep the old value. Done changes only that stop. Apply to all explicitly changes all draft stops.
4. Save/reopen, duplicate and export/import a trip with a 24-hour stop. Confirm the precise value survives. Older 2.5.0/2.5.1 builds cannot import waits beyond their one-hour limit.
5. Preview the trip; jump to the long stop, play briefly, pause, then seek back to restore the full duration. Use Skip wait to continue rehearsal without waiting a day. Preview must not send a location command.
6. Run a short actual stop and pause halfway. The countdown freezes; resume completes it once. Insert a future long stop during travel and verify it is accepted. Test a long stop's initial countdown and recovery without claiming a full-day device run.
7. Give two stops 24 hours each. Their aggregate wait must show 48 hr, not 24 hr or a raw seconds total. Travel time remains separate.
8. Check the smallest supported iPhone, landscape, VoiceOver and largest text. Wheels must scroll independently; accessibility text uses readable menus. Done/Cancel and Apply to all stay reachable.

A 24-hour planned stop is not a promise of uninterrupted background operation or
24-hour Dynamic Island visibility. Countdown time advances only with a running,
fresh route worker; interruption time is not deducted. See [verification limits](VERIFICATION.md).

## 2.5.1 (49) interface checks

- Change an icon under Settings → Appearance → Choose App Icon. Stay on the same tab and scroll position before and after the iOS confirmation. Only the requested icon shows progress; rapid extra taps must not submit another request. Repeat with app lock and Hide in App Switcher enabled, then confirm real backgrounding still protects content. The flicker fix needs this physical-device check.
- Start a route. The compact map panel exposes target speed, remaining distance, progress, Pause/Resume and Stop spoofing. Its menu retains Route details, Mode & speed, shortcuts and End route and hold location. Verify End route holds the last position and Stop spoofing attempts to clear simulation.
- Inspect active, paused, waiting, arriving, disconnected, retrying and stopping states. Connection evidence and countdowns must remain visible. Check large text, landscape, VoiceOver and Reduce Motion; controls must remain reachable.
- In the planner, tap a timeline place, a travel section, and a wait. Reorder or remove a stop through its menu. Verify mixed-mode settings, drawn/GPX paths and saved paths retain their original semantics.
- Choose 0, 5, 15, 30 or 60 seconds, type a custom value, and test Cancel/Done. Apply to all should change every stop only after that explicit action. Save/reopen the trip and verify waits.
- Open Preview. Drag the position slider forward/backwards and use Jump to a stop. Seeking pauses playback; earlier stops become eligible again when seeking backwards. Landing on a stop restores its complete wait. Preview controls must never move the actual device location or affect a concurrent session.

This update keeps 2.5.0's app identity and can update that installation under the
same signing setup. It does not introduce a rebrand or automatic route starts.

## Moving from Shift 2.4.x

The new bundle ID lets Shift and Locus coexist. It also means iOS gives Shift
2.5.0 its own storage instead of opening the old installation's data.

1. In the old Shift app, export a library backup using Settings → Files & backups
   (or the export/import screen in that version). Include places, trips and settings.
2. Save the backup somewhere you can find in Files. Keep the old app installed
   until the new one is working and you have checked the imported library.
3. Stop spoofing in the old app and confirm it cleared successfully.
4. Sign/install the new IPA with its extension and independent app ID. Check
   your sideloading tool's active-app allowance before keeping both installations.
5. Set up pairing and LocalDevVPN in the new app. Pairing secrets, helper credentials,
   app-lock state, recents, edit history and detailed logs are not in library backups.
   Reconfigure the optional helpers and app lock if used.
6. Import the library backup, inspect places/trips, and enable notification permission
   if desired. Recreate Home Screen widgets for the new installation. Update old
   `locus://` shortcuts to `shift://` when they should open Shift.
7. Use only one location-simulation app at a time: separate installations still
   control the same phone's simulated location.

## Device acceptance checks

| Check | Expected result |
| --- | --- |
| Install next to Locus | Both apps remain installed; Shift widgets and Live Activities belong to Shift. |
| Stop waits: 0, 1, 15, 30, 59, 90 seconds | Controls accept each value; 0 passes through, 90 displays 1 min 30 sec. Save/reopen/export/import retains the value. |
| Pause during a 15-second stop | Pausing freezes the remaining wait; resuming finishes it once. No time is consumed while suspended. |
| Change mph ↔ km/h during travel | Display updates across the app; target movement speed and ETA stay unchanged. |
| Set 36 km/h, drive, smooth movement off | The route's target is 10 m/s. In uninterrupted playback, 60 seconds of accepted movement covers about 600 m. Connection delays can slow observed progress. |
| Metric slider and VoiceOver adjustment | Speeds follow the metric scale and stay within the mode's physical limits. |
| Saved route, section override, history, backup | All speed displays follow the preference. Existing MPH fields are read as MPH; the preference survives a new backup/import. |
| Background reminder/connection notification | Tapping opens session details after unlocking. A route editor shows the existing close-editor guidance. |
| Foreground connection error | One in-app alert; no duplicate connection banner/sound. Connection details is available from the alert. |
| Import broken XML, unrelated plist or wrong pairing format | Existing pairing and revision stay unchanged. A validated RPPairing can replace it. |
| Fresh install, then logging opt-in | Detailed logging starts off. Enabling it records later actions. Existing explicit preferences are honored. |
| Largest Dynamic Type / VoiceOver | Stop input, speed selection, actions and About title remain usable. |

## Automated checks

The Mac workflow runs Foundation model tests, helper tests, identity checks and
the app/extension build, then validates the packaged IPA. New regression cases
cover exact metric conversion, real playback distance/ETA, short-stop completion,
old/new backup compatibility, pairing replacement, logging defaults and compiled
bundle identity. Build/test results are recorded in the chat that produced the IPA;
this checklist is not a claim that device testing has passed.
