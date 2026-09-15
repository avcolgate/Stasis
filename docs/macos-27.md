# macOS 27 compatibility work

This branch addresses battery reporting and menu-bar behavior observed on macOS 27.0 build 26A428 (Mac14,9). It is not a claim of complete charging-control support across macOS 27 hardware.

## Reporting and notifications

- Missing capacity fields no longer produce a fabricated 100% battery-health value. Health uses Apple's `system_profiler SPPowerDataType` report, refreshed in the background every 30 minutes. Legacy raw capacities and macOS 27's nested `BatteryData` capacities provide a labeled estimate when the report is unavailable; missing data remains unknown.
- Charging notifications follow actual IOKit state transitions independently of SMC charging support or the Manage charging setting. The first valid reading establishes a baseline without announcing a transition.
- Adapter connection changes also generate notifications, even when charging remains paused at the native 80% limit. A connection change takes precedence when connection and charging change in the same reading.
- A test-notification button reports permission/delivery errors. Foreground presentation requests a banner, Notification Center entry, and sound. macOS Focus and screen-sharing settings can still suppress presentation.
- The status-bar charging/plug icon follows live IOKit connection and charging state. It no longer depends on wattage, which is polled only while the menu is open. Opening the menu also no longer overwrites charging state with an SMC power estimate.
- Live signed IOKit current distinguishes discharge while AC is physically attached. Battery voltage/current/power prefer OS readings when present; stale SMC wattage cannot change an idle OS state. With zero adapter input, the diagram uses battery-to-Mac flow. Discharge mode includes watts.
- Charge Limit Override has explicit On/Off text as well as green tint.

## Charging control: experimental

The legacy charging-inhibition keys were unavailable on the tested Mac, while adapter-isolation metadata remained readable. Adapter isolation is not a replacement for pausing charging while retaining AC power. The app requires native PowerUI, direct charging control, or firmware control before enabling charge management.

The branch includes a guarded firmware path for `bfF0`, `bfD0`, and `bfE0`: validated thresholds, little-endian encoding, ordered writes, read-back verification, rollback, and restoration of the original settings when the charging helper disconnects. The read-only capability probe can run in the root helper. Automatic discharge and heat protection are not offered in firmware mode.

**On the tested build, SMCKit returned `notPrivileged` even from the root charging helper. No firmware charge-limit writes were performed on hardware.** Encoding and rollback tests use simulated registers. Successful firmware control, helper restoration on supported hardware, and compatibility with older macOS versions still need hardware testing. Keep macOS's native Battery charge limit enabled when Stasis reports unsupported control.

A subsequent standalone C probe using the dependency's SMC transport reproduced `0xe00002c1` (`notPrivileged`) for metadata reads of all three firmware keys, both as UID 501 and UID 0, on firmware 20457.1.29. `CHTE` was absent and `CHIE` metadata remained readable. This rules out the XPC helper as the sole cause; it does not establish that changing SMC libraries will restore access. Readable `CHIE` metadata alone is not proof that force-discharge writes work.

Register reference: [batt v0.8.0 charging implementation](https://github.com/charlie0129/batt/blob/v0.8.0/pkg/smc/charging.go).

### Alternative control investigation (2026-09-15)

The PowerUI round-trip hardware test succeeded: after restoring 80% at 17:44:37, `pmset -g batt` again reported `AC attached; not charging` at approximately 17:45:32. Both resume and pause took roughly one minute to reach the observed battery state; API success alone is insufficient verification.

A read-only executable built against batt v0.8.0 (`f25fef31ee247bbe81df468cb2523a8015c12f12`) and its pinned gosmc dependency reproduced the firmware-key access denial as both UID 501 and UID 0. It reported `mode=unsupported`; `CHIE` was readable as `00`. Installing batt's daemon is therefore not an established workaround on this machine.

Inspection of the official AlDente 1.39.2 application identified a PowerUI fallback. A standalone Objective-C probe loaded Apple's private PowerUI framework and used `PowerUISmartChargeClient`. Its read APIs succeeded without root, reporting manual charge limiting enabled at 80%, and available limits `[80, 85, 90, 95, 100]`. `setMCLLimit:error:` accepted 100 and read it back. The battery remained paused at first, then `pmset -g batt` reported actual charging at the 60-second observation. The probe restored the original 80% limit and verified that manual charge limiting was enabled again. This API is private, and its available range does not establish support for below-80% sailing.

### Native integration

Stasis now runtime-checks PowerUI support and offers its advertised 80–100% limits. It accepts an enabled native limit or the 100% unlimited state (which macOS reports as disabled); other disabled configurations are not implicitly enabled. This backend takes precedence over SMC, needs no privileged helper, and continues using OS battery readings. Native mode does not expose sailing, force discharge, or heat protection.

The original limit is journaled before writes. Disabling management or quitting restores it; restart retries recovery before applying management again. The temporary 100% override restores the configured limit on cancel, unplug, or reaching 100%. A failed restore retains the journal and prevents normal quit with an actionable error. A crash cannot restore the limit until Stasis launches again; macOS may charge toward 100% in the meantime.

Firmware writes use typed UInt8/UInt32 APIs rather than SMCKit's hex-only `writeData`; their little-endian encoding is covered by regression tests. Hardware firmware writes remain unverified.

Installed-app test: enabling Manage charging exposed the native 80% picker. The tester enabled Charge Limit Override from the menu. A separate read-only probe confirmed the native target became 100%, and `pmset -g batt` reported 81%, charging. This also reproduced macOS reporting native limiting as disabled at 100%; detection was corrected to permit recovery in that state.

The tester then unplugged/reconnected and confirmed the override switched off. The system target read back as 80%; screenshots showed connected/charging-paused notifications at 86%. OS signed current confirmed discharge while AC remained attached. Normal quit retained 80% and removed the recovery journal; the final build reopened successfully.

## Validation

### Time to selected target

When charge management is enabled, Time Remaining estimates minutes to the configured percentage (100% during override). It uses the OS display-percentage gap, full-charge capacity in mAh, and a time-weighted moving average of measured current with a 60-second time constant. This keeps the percentage display unchanged and avoids mixing raw and displayed state-of-charge scales. Estimates are prefixed with `≈`; they are not macOS-provided predictions and cannot anticipate future load or charge taper.

Exception: while charging toward 100%, a valid OS time-to-full estimate takes precedence because it can account for charge taper. The current-rate estimate is the fallback until macOS supplies one. A live test reproduced this distinction: the raw-current projection was about 19 minutes, while macOS subsequently supplied about 59 minutes to full.

At least 15 seconds of distinct readings are required. Target, adapter, and current-direction changes reset history. Missing/nonfinite capacity or current, readings older than two minutes, and estimates beyond 48 hours show `Estimating…`. Idle or away-from-target movement shows `Not approaching target`. Only a plugged-in, noncharging, near-zero-current battery at the displayed target shows `∞ · Holding at …%`. Opening the menu refreshes OS readings alongside the existing polling. With management disabled, the original OS time-remaining display is retained.

Automated cases cover both charging/discharging ETAs, smoothing, duplicate snapshots, override reset, holding/unplugging, stale/malformed data, and capacity-field selection. A signed Debug build and installed-app signature verification passed for this change.

Live display validation: the tester confirmed `∞ · Holding at 80%`, then confirmed approximately 26 minutes to 100% while the diagram showed 25 W into the battery and 35 W into the Mac from 60 W adapter input. The native transition and estimator warm-up are not instantaneous. The subsequent OS-time-to-full preference has a regression test; the installed refinement restored the configured 80% limit during restart.

Run the production-model regression checks with:

```sh
./Tests/run.sh
```

The checks cover missing/nested/legacy health data, reported health parsing, notification transition deduplication, menu-closed charging-icon states, and firmware encoding/rollback. A signed Release build succeeded locally. Building requires selecting your own signing team; the repository's signing settings are unchanged.

Local runtime checks confirmed Apple's reported health at 82% instead of the previous fallback of 100%, and notification requests were accepted with foreground banner/list/sound presentation requested. A visible notification may still be suppressed by macOS. After installing the rebuilt app, the tester unplugged and reconnected the charger with the menu closed and confirmed the icon updated automatically. This physical check complements the automated state tests.
