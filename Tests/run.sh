#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_directory="$(mktemp -d)"
trap 'rm -rf "$build_directory"' EXIT
swiftc Stasis/Models/BatteryMetrics.swift Stasis/Models/BatteryReading.swift Stasis/Models/ChargingMode.swift Stasis/Models/PowerSource.swift Tests/RegressionTests.swift -o "$build_directory/regressions"
"$build_directory/regressions"
swiftc SMCPower/FirmwareChargeLimit.swift Tests/FirmwareTests.swift -o "$build_directory/firmware"
"$build_directory/firmware"
swiftc Stasis/Services/NativeChargeSession.swift Tests/NativeChargeTests.swift -o "$build_directory/native"
"$build_directory/native"
