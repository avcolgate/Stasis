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
swiftc Stasis/Models/BatteryMetrics.swift Stasis/Models/TargetTimeEstimator.swift Tests/TargetTimeTests.swift -o "$build_directory/target-time"
"$build_directory/target-time"
swiftc -parse-as-library Stasis/Models/BatteryMetrics.swift Stasis/Models/ChargingMode.swift Stasis/Models/PowerSource.swift Stasis/Views/PowerSankeyView.swift Tests/PowerDiagramTests.swift -o "$build_directory/power-diagram"
"$build_directory/power-diagram"
