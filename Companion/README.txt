SHIFT WINDOWS HELPER — 2.3.2

This optional helper reads a selected Find My DEVICE or Life360 profile and sends
that report to Shift. Shift compares the report's location time with the point it
successfully sent at that time. It never treats a new download of an old location
as a fresh match. No app on your iPhone can read another app's private location
state directly.

WHAT IT CAN AND CANNOT CHECK

- Find My Devices: select your iPhone after signing in to your Apple Account.
  This does NOT establish the People location that friends see. People may use
  a different sharing device. Automatic Find My People checking is unavailable
  in this Windows helper.
- Life360: use a separate, consenting Circle member's observer account that can
  already see your own profile. Select your profile, not someone else's.
  Life360 warns that signing the same account into multiple phones can sign out
  the first phone. Do not use the phone's own account for this experiment.
- Both connectors are unofficial and may stop working if their service changes.
  A blocked request, rate limit, sign-in challenge, or missing location never
  produces a match. Resolve sign-in through the official service before retrying.
- A match is a fresh report matching a Shift point within the stated accuracy.
  It does not prove every observer has refreshed or guarantee future updates.

START ON WINDOWS

1. Extract the entire companion ZIP into a normal folder.
2. Double-click Start Companion.cmd. The launcher uses the bundled Codex Python
   when available, otherwise Python from PATH. It installs the tested dependencies
   into a .venv folder here. If Python is missing, install Python 3.12 or 3.13
   from python.org with Add Python to PATH enabled, then open the launcher again.
   Dependency imports and a local TLS test passed on this Windows ARM laptop
   using its bundled Python 3.12.14. Service sign-in has NOT been tested.
3. Press Enter to use the detected local address, or enter the Wi-Fi IPv4 address
   shown in Windows Settings > Network & Internet > Wi-Fi > Properties.
   Choose the Wi-Fi address, not an unrelated VPN tunnel address.
4. Choose the services to check. Enter credentials and any Apple verification
   code locally in this window. Do not paste passwords into chat.
5. Select your iPhone / Life360 profile from the numbered list.
6. Allow Python on PRIVATE networks if Windows Firewall asks. The helper listens
   only on the Wi-Fi address you chose. Do not forward its port on your router.
7. Transfer ShiftCompanionPairing.json privately to your iPhone's Files app.
   In Shift, open Settings > Find My checks > Windows helper > Set up computer checks
   > Import setup file. Older setup files remain compatible.
   Confirm that it came from your own computer. The file contains a secret access
   token and certificate fingerprint: do not put it on GitHub or share it publicly.
8. Keep both devices on the same Wi-Fi and the companion window open. Shift’s
   LocalDevVPN can stay connected. If the Wi-Fi isolates devices, the check may
   be unavailable; that is separate from the spoofing session's connection.
9. Tap Test connection. Enable Use Windows helper, then start a Shift session.
   Reports refresh about once a minute while iOS lets Shift run, including away
   from this screen. Find My status also appears in Shift's Live Activity.
   Refresh reports fetches the latest cached report; it cannot force a new Apple
   location. The Cloud helper is an alternative when your laptop is off.

STOP / RESTART

Press Ctrl+C in the companion window to stop. Disconnect computer in Shift removes
its stored pairing. This version retains the pairing identity across restarts
on the same address. Sign in again in the helper, but keep the saved iPhone setup.
After an address change, key reset, or certificate renewal, import the new file.
Upgrading from the old helper requires one new import. Delete transfer copies.

The saved identity is protected for your Windows user with DPAPI in
%LOCALAPPDATA%\ShiftCompanion\identity.dat. Apple/Life360 passwords are not saved.
To revoke existing phone access, stop the helper and run:
  .\.venv\Scripts\python.exe companion.py --reset-pairing
Then import its new ShiftCompanionPairing.json in Shift.
On a normal exit, the helper removes its generated pairing file and temporary
Apple session cache. It does not save your passwords. If force-closed, temporary
session files may remain under %LOCALAPPDATA%\ShiftCompanion; remove those specific
session-* folders after the helper has stopped if you want to clear them.

PRIVACY AND RELIABILITY

- The helper returns only the selected target's name, location, location timestamp,
  accuracy, provider and check status. No credentials go to Shift.
- Shift’s pairing is stored in iOS Keychain, excluded from library backups.
- The connection uses HTTPS pinned to the imported certificate and a random
  access token. It refuses redirects. There are no account-control endpoints.
- Command history used for comparison stays in memory for at most five minutes
  and is cleared when the session stops. Location reports are not saved to files.
- The helper checks each selected provider at most once a minute. Authentication
  and service-block failures stop that provider until you restart. There is no
  challenge bypass, automatic password guessing, or rapid retry loop.
- Enable Use Windows helper to check during location sessions. Cloud and Windows
  sources are mutually exclusive, but both pairings can remain saved. iOS can
  suspend the app; old reports expire even when requests stop returning. This is
  not an always-on safety monitor. Laptop sleep or leaving its Wi-Fi breaks the
  local connection. Use Cloud helper for checks away from your computer.
- Settings > Connection > Connection checks controls Shift's own 3-15 second
  connection cadence (default 10), including Live Activity status. This does not
  change the once-a-minute Apple polling or make Apple supply newer locations.
- Keep Windows and iPhone automatic date/time enabled. Missing or future timestamps,
  service-marked old data, wide accuracy and gaps during writes cannot match.
- The provider's reported accuracy must be 100 m or better. The displayed match
  radius is at least 15 m and otherwise the provider's accuracy. This accommodates
  ordinary positioning uncertainty; it is not exact-address confirmation.

CONNECTION TROUBLESHOOTING

A 401 in Safari at the printed /reports address means the helper is reachable.
Safari has no pairing key. Test connection inside Shift supplies it. If Shift
says the setup file was rejected, import the file from the currently running
helper. A certificate error needs the matching file too; do not disable TLS.
Enable Local Network access for Shift or its LiveContainer/SideStore host.

OPTIONAL OFFLINE TESTS

After the first successful install, open PowerShell in this folder:
  .\.venv\Scripts\python.exe -m unittest discover -p "test_*.py" -v
  .\.venv\Scripts\python.exe check_install.py -v

These use sample data and a localhost HTTPS server. They do not sign in to accounts.
The main app's GitHub workflow runs the sample-report tests as well as Swift tests.

SOURCES / DEPENDENCIES

Apple Find My on iCloud (Devices):
https://support.apple.com/en-ca/guide/icloud/mmfc0f2442/icloud
Apple location sharing / sharing source:
https://support.apple.com/en-mide/guide/iphone/iph01954dc44/26/ios/26
Life360 account/device guidance:
https://support.life360.com/hc/en-us/articles/23053659701655-Life360-on-Multiple-Devices
Apple connector (pyicloud 2.7.0): https://github.com/timlaing/pyicloud
Life360 connector (7.2.0): https://github.com/pnbruckner/life360
Life360 timestamp and accuracy-unit reference:
https://github.com/pnbruckner/ha-life360/blob/master/custom_components/life360/helpers.py
HTTPS certificates: https://cryptography.io/

Dependencies are installed from PyPI, not bundled as modified third-party code.
Their licenses are included in the installed packages. This helper uses the
Locus source repository's MIT license.
