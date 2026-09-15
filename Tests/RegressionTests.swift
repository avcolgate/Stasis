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
        check(BatteryReading.fullChargeCapacityMAh(from: ["BatteryData": ["AppleRawMaxCapacity": NSNumber(value: 4708)]]) == 4708, "ETA capacity supports nested native capacity")
        check(BatteryReading.fullChargeCapacityMAh(from: ["MaxCapacity": 100]) == nil, "ETA never treats normalized percentage as mAh")
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
        var connection = PowerConnectionTracker()
        check(connection.update(connected: true, valid: true, enabled: true) == nil, "connection startup is silent")
        check(connection.update(connected: false, valid: true, enabled: true) == false, "unplug emits even when charging already paused at limit")
        check(connection.update(connected: true, valid: true, enabled: true) == true, "plug emits even when charging remains paused")
        check(connection.update(connected: true, valid: true, enabled: true) == nil, "connection readings deduplicate")
        check(connection.update(connected: false, valid: false, enabled: true) == nil, "invalid connection reading ignored")
        check(connection.update(connected: false, valid: true, enabled: false) == nil, "disabled connection notification suppressed")
        check(connection.update(connected: false, valid: true, enabled: true) == nil, "connection enable does not replay")
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
        battery.externalConnected = true
        battery.isCharging = false
        battery.osBatteryCurrent = -2.08
        check(ChargingMode.current(battery: battery) == .discharging, "live OS current identifies discharge while attached")
        check(PowerSource.current(battery: battery, adapter: AdapterMetrics()) == .battery, "zero adapter watts with live discharge uses battery flow")
        battery.osBatteryCurrent = 0
        check(ChargingMode.current(battery: battery) == .pluggedIn, "stale SMC wattage cannot override idle OS current")
        check(BatteryReading.signedAmperage(NSNumber(value: UInt64.max - 1843)) == -1.844, "unsigned OS current decodes negative milliamps")
        exit(failures == 0 ? 0 : 1)
    }
}
