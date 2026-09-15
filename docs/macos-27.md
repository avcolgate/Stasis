# macOS 27 compatibility work

This branch addresses battery reporting and menu-bar behavior observed on macOS 27.0 build 26A428 (Mac14,9). It is not a claim of complete charging-control support across macOS 27 hardware.

## Reporting and notifications

- Missing capacity fields no longer produce a fabricated 100% battery-health value. Health uses Apple's `system_profiler SPPowerDataType` report, refreshed in the background every 30 minutes. Legacy raw capacities and macOS 27's nested `BatteryData` capacities provide a labeled estimate when the report is unavailable; missing data remains unknown.
- Charging notifications follow actual IOKit state transitions independently of SMC charging support or the Manage charging setting. The first valid reading establishes a baseline without announcing a transition.
- A test-notification button reports permission/delivery errors. Foreground presentation requests a banner, Notification Center entry, and sound. macOS Focus and screen-sharing settings can still suppress presentation.
- The status-bar charging/plug icon follows live IOKit connection and charging state. It no longer depends on wattage, which is polled only while the menu is open. Opening the menu also no longer overwrites charging state with an SMC power estimate.

## Charging control: experimental

The legacy charging-inhibition keys were unavailable on the tested Mac, while adapter-isolation control remained available. Adapter isolation makes the Mac run from its battery and is not a replacement for pausing charging while retaining AC power. The app now requires direct charging control or firmware control before enabling charge management.

The branch includes a guarded firmware path for `bfF0`, `bfD0`, and `bfE0`: validated thresholds, little-endian encoding, ordered writes, read-back verification, rollback, and restoration of the original settings when the charging helper disconnects. The read-only capability probe can run in the root helper. Automatic discharge and heat protection are not offered in firmware mode.

**On the tested build, SMCKit returned `notPrivileged` even from the root charging helper. No firmware charge-limit writes were performed on hardware.** Encoding and rollback tests use simulated registers. Successful firmware control, helper restoration on supported hardware, and compatibility with older macOS versions still need hardware testing. Keep macOS's native Battery charge limit enabled when Stasis reports unsupported control.

Register reference: [batt v0.8.0 charging implementation](https://github.com/charlie0129/batt/blob/v0.8.0/pkg/smc/charging.go).

## Validation

Run the production-model regression checks with:

```sh
./Tests/run.sh
```

The checks cover missing/nested/legacy health data, reported health parsing, notification transition deduplication, menu-closed charging-icon states, and firmware encoding/rollback. A signed Release build succeeded locally. Building requires selecting your own signing team; the repository's signing settings are unchanged.

Local runtime checks confirmed Apple's reported health at 82% instead of the previous fallback of 100%, and notification requests were accepted with foreground banner/list/sound presentation requested. A visible notification may still be suppressed by macOS. After installing the rebuilt app, the tester unplugged and reconnected the charger with the menu closed and confirmed the icon updated automatically. This physical check complements the automated state tests.
