import Foundation

@main
struct RegressionTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        check(BatteryMetrics().batteryHealth == nil, "missing health is unknown")
        let modern: [String: Any] = ["MaxCapacity": 100, "BatteryData": ["DesignCapacity": 6075, "FullChargeCapacity": 4736, "RemainingCapacity": 3613]]
        check(BatteryReading.estimatedHealth(from: modern) == 77, "nested macOS 27 capacity fields, not normalized MaxCapacity")
        check(BatteryReading.capacities(from: modern).current == 3613, "nested raw remaining capacity")
        check(BatteryReading.estimatedHealth(from: [:]) == nil, "missing data never becomes 100 percent")
        check(BatteryReading.estimatedHealth(from: ["AppleRawMaxCapacity": 5000, "DesignCapacity": 0]) == nil, "zero design capacity is unknown")
        check(BatteryReading.estimatedHealth(from: ["AppleRawMaxCapacity": 4800, "DesignCapacity": 6000]) == 80, "legacy capacity layout")
        let report = Data(#"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_health_maximum_capacity":"82%"}}]}"#.utf8)
        check(BatteryReading.reportedHealth(from: report) == 82, "Apple health is parsed independently of raw estimate")
        check(BatteryReading.reportedHealth(from: Data("invalid".utf8)) == nil, "malformed report is unknown")
        check(BatteryReading.reportedHealth(from: Data(#"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_health_maximum_capacity":"0%"}}]}"#.utf8)) == nil, "invalid reported health rejected")
        var tracker = ChargingTransitionTracker()
        check(tracker.update(isCharging: false, valid: false, notificationsEnabled: true) == nil, "no notification on missing startup reading")
        check(tracker.update(isCharging: true, valid: true, notificationsEnabled: true) == nil, "first valid reading establishes baseline")
        check(tracker.update(isCharging: false, valid: true, notificationsEnabled: true) == false, "actual pause emits without hardware capability or charge management")
        check(tracker.update(isCharging: false, valid: true, notificationsEnabled: true) == nil, "repeated readings do not duplicate alerts")
        check(tracker.update(isCharging: true, valid: false, notificationsEnabled: true) == nil, "invalid reading cannot create a transition")
        check(tracker.update(isCharging: true, valid: true, notificationsEnabled: false) == nil, "disabled notifications suppress transition")
        check(tracker.update(isCharging: true, valid: true, notificationsEnabled: true) == nil, "reenabling does not replay stale transitions")
        check(tracker.update(isCharging: false, valid: true, notificationsEnabled: true) == false, "pause after reenable")
        check(tracker.update(isCharging: true, valid: true, notificationsEnabled: true) == true, "resume after reenable")
        var battery = BatteryMetrics()
        battery.externalConnected = true
        battery.isCharging = true
        battery.batteryPower = -12
        check(ChargingMode.current(battery: battery) == .charging, "plug-in updates icon before first SMC wattage poll")
        battery.isCharging = false
        check(ChargingMode.current(battery: battery) == .pluggedIn, "charge limit shows plug with zero or stale wattage")
        battery.externalConnected = false
        check(ChargingMode.current(battery: battery) == .discharging, "unplug updates icon despite cached adapter wattage")
        battery.isCharging = true
        check(ChargingMode.current(battery: battery) == .discharging, "disconnected power takes precedence over stale charging state")
        exit(failures == 0 ? 0 : 1)
    }
}
