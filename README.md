# Stasis

**A smarter battery icon for your MacBook.** Monitor power metrics, manage charge limits, and extend your battery's lifespan — all from the menu bar.

Stasis gives you real-time insight into your MacBook's power system and lets you control charging behavior directly, without relying on macOS's opaque "Optimized Battery Charging."

> **This is a fork of [srimanachanta/Stasis](https://github.com/srimanachanta/Stasis) with macOS 27 support.**
> It includes the unmerged upstream [PR #31](https://github.com/srimanachanta/Stasis/pull/31) and the following changes:
>
> - **Charge limit on macOS 27.** macOS 27 no longer lets apps pause charging through the SMC, so the limit is set through macOS's own charge limit (80–100%). A limit you set by hand in System Settings, such as 88%, is kept and restored.
> - **Live power readings.** Current, wattage and charging state come from the SMC, because macOS 27 reports them up to a minute late. Battery temperature is read from the SMC too, since macOS 27 no longer provides it.
> - **Redesigned menu.** A power-flow diagram with ribbons sized by wattage and colored by source, a charge bar with a limit marker, and clearer voltage, current and power rows.
>
> Install this version from this fork's [Releases](https://github.com/avcolgate/Stasis/releases) or build it yourself (see below). The Homebrew cask installs the original app without these changes.

> **Apple Silicon only.** The heuristics and mechanics to interface with metrics and charging between both of these platforms varies a lot. Currently, the app only supports Apple Silicon MacBooks.
>
> Requires **macOS 14.8+**.

![Stasis Menu Bar](https://github.com/srimanachanta/Stasis/wiki/images/FullApp.jpg)

## Installation

### Download a release

1. Download the latest `Stasis-*.zip` from this fork's [Releases](https://github.com/avcolgate/Stasis/releases).
2. Unzip it and move **Stasis.app** to `/Applications`.
3. The app is not notarized by Apple, so remove the quarantine flag before the first launch:
   ```bash
   xattr -cr /Applications/Stasis.app
   ```
4. Open Stasis from Applications.

To turn on charge limiting, open **Settings → Charging** and enable **Manage charging**. On macOS 27 this uses the system charge limit and needs no extra permissions.

### Original version

The upstream app (without this fork's changes) is available via Homebrew:

```bash
brew install --cask srimanachanta/tap/stasis
```

## Highlights

- **Charge Limit** — Set a max charge level (50–100%) enforced at the hardware level, even through sleep.
- **Sailing Mode** — Avoid micro-charging by letting the battery float within a configurable range.
- **Automatic Discharge** — Drain to your target level while staying plugged in.
- **Heat Protection** — Pause charging when battery temperature gets too high.
- **Power Dashboard** — Live voltage, current, wattage, temperature, health, and cycle count in the menu bar.
- **Power Flow Diagram** — Sankey visualization of real-time power distribution.
- **MagSafe LED Control** — Green at limit, orange while charging.

## Documentation

For detailed feature explanations, settings walkthroughs, architecture info, and FAQ, see the **[Stasis Wiki](https://github.com/srimanachanta/Stasis/wiki)**.

## Building from Source

Requires Xcode with Swift 6 support. Accept the Xcode license once with `sudo xcodebuild -license accept`.

```bash
git clone https://github.com/avcolgate/Stasis.git
cd Stasis

xcodebuild -project stasis.xcodeproj -scheme stasis -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build \
  -skipMacroValidation -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  ENABLE_HARDENED_RUNTIME=NO build

app=build/Build/Products/Release/stasis.app
codesign --force --sign - --identifier com.srimanachanta.stasis.charging-helper \
  "$app/Contents/Library/LaunchDaemons/charging-helper"
codesign --force --sign - "$app"

rm -rf /Applications/Stasis.app
cp -R "$app" /Applications/Stasis.app
open /Applications/Stasis.app
```

This builds without an Apple developer account by signing locally (ad hoc). Hardened runtime is turned off and the charging helper is signed again, because an ad-hoc signed app with hardened runtime cannot load its own embedded framework and crashes at launch. Quit Stasis before replacing an installed copy; `rm -rf` first, because `cp -R` onto an existing app would place the new copy inside the old one.

Run the regression checks with `./Tests/run.sh`.

## Contributing

PRs welcome. Please open an issue first for large changes.

## Acknowledgments

- [SMCKit](https://github.com/srimanachanta/SMCKit) — SMC access library
- [AsahiLinux](https://asahilinux.org/) — SMC key reverse engineering
- [Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit) — SMC key documentation

## License

[GPL-3.0](LICENSE)
