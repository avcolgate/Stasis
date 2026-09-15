#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
build_directory="$(mktemp -d)"
trap 'rm -rf "$build_directory"' EXIT
swiftc Stasis/Models/BatteryMetrics.swift Stasis/Models/BatteryReading.swift Stasis/Models/ChargingMode.swift Tests/RegressionTests.swift -o "$build_directory/regressions"
"$build_directory/regressions"
swiftc SMCPower/FirmwareChargeLimit.swift Tests/FirmwareTests.swift -o "$build_directory/firmware"
"$build_directory/firmware"
