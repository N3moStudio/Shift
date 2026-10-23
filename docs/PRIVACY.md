# Data and limitations

Shift ships without a personal account, helper URL, helper key, pairing file,
signing identity, saved places, or an active deployment. Optional helpers belong
to each person who configures them.

## What stays on the device

Saved places, areas, routes, settings, recovery state, and edit history are local.
Optional app lock uses device authentication. Location-name privacy for the
Lock Screen and Dynamic Island does not hide information in other apps.

Library exports contain readable location data and supported preferences. They
exclude pairing secrets and helper credentials. Review where you save them.
Detailed developer logging is off by default in new installations; an existing
explicit recording preference is preserved. When enabled, the developer log may
include precise coordinates and user-entered notes;
review exports before sharing. It uses fixed 48-hour batches and a 256 MiB cap.
Expiry cleanup needs the app to execute; exported copies are outside its control.
No diagnostic log is automatically uploaded.

## What connects to the network

Apple Maps services provide map tiles, search and directions. The developer
tunnel sends simulated-location commands to the paired iPhone. A configured
helper exchanges authorized location reports and comparison data with the app.
Running Shift is not a promise that all network activity stays on-device.

Cloud and Windows helpers are optional and unofficial. Their setup files are
access credentials. Keep them, Apple sign-in data, `.env` files and signing keys
out of GitHub. The cloud helper’s Apple login is lost on restart. The Windows
helper protects its persistent identity for its Windows user; a changed network
address or renewed credentials can require importing a new setup file.

## What confirmation means

- A recent successful command is evidence that the location service accepted that command.
- A fresh matching Find My **Devices** report is separate evidence, limited to its timestamp and accuracy. It does not verify Find My People or every observer’s screen.
- An old report, an unavailable helper, or missing command evidence must not be treated as a fresh confirmation.
- iOS may suspend or terminate the app, delay notifications, and mark a Live Activity stale. There is no independent always-on push alarm.
- Closing the app is not the same as successfully clearing a simulated location.

Ordinary notification icons are system-controlled. Icon resources and native
alternate-icon selection do not guarantee that iOS refreshes a cached icon.
The test-banner feature introduced briefly in 2.4.3 is removed in 2.4.4.

Battery optimizations reduce unnecessary work, but no universal battery-life
improvement has been measured. Reliability comparisons show whole-phone battery
changes, not energy attributed exclusively to Shift.
