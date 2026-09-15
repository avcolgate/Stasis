import Foundation

@main struct TargetTimeTests {
    static func main() {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL"): \(name)")
            if !value { failures += 1 }
        }
        var estimator = TargetTimeEstimator()
        var battery = BatteryMetrics()
        battery.hasPowerSourceData = true
        battery.externalConnected = true
        battery.batteryPercentage = 70
        battery.fullChargeCapacityMAh = 5000
        battery.osBatteryCurrent = 1
        battery.isCharging = true
        battery.powerSampleTime = 10
        battery.timeRemaining = 60
        check(estimator.update(battery, target: 100, now: 10) == .minutes(60, target: 100), "native time-to-full takes precedence for a 100 percent target")
        battery.timeRemaining = -1
        check(estimator.update(battery, target: 80, now: 10) == .estimating, "target estimate warms up")
        check(estimator.update(battery, target: 80, now: 30) == .estimating, "duplicate snapshot does not warm up estimator")
        battery.powerSampleTime = 30
        check(estimator.update(battery, target: 80, now: 30) == .minutes(30, target: 80), "charge ETA uses capacity and measured rate")
        battery.osBatteryCurrent = 2
        battery.powerSampleTime = 40
        let smoothed = estimator.update(battery, target: 80, now: 40)
        if case .minutes(let minutes, _) = smoothed {
            check(minutes > 15 && minutes < 30, "current spike is smoothed")
        } else { check(false, "current spike is smoothed") }
        check(estimator.update(battery, target: 100, now: 40) == .estimating, "override target resets history")
        battery.isCharging = false
        battery.batteryPercentage = 86
        battery.osBatteryCurrent = -1
        battery.powerSampleTime = 60
        check(estimator.update(battery, target: 80, now: 60) == .estimating, "direction change resets history")
        battery.powerSampleTime = 80
        check(estimator.update(battery, target: 80, now: 80) == .minutes(18, target: 80), "discharge ETA approaches selected target")
        battery.batteryPercentage = 80
        battery.osBatteryCurrent = 0
        battery.powerSampleTime = 90
        check(estimator.update(battery, target: 80, now: 90) == .holding(80), "idle at target on adapter shows infinity")
        battery.externalConnected = false
        check(estimator.update(battery, target: 80, now: 90) != .holding(80), "unplugged at target never shows infinity")
        battery.batteryPercentage = 75
        battery.osBatteryCurrent = -1
        battery.powerSampleTime = 100
        check(estimator.update(battery, target: 80, now: 100) == .notApproaching, "moving away from target has no ETA")
        battery.externalConnected = true
        battery.osBatteryCurrent = 0
        check(estimator.update(battery, target: 80, now: 100) == .notApproaching, "paused below target has no ETA")
        battery.batteryPercentage = 80
        check(estimator.update(battery, target: 80, now: 250) == .estimating, "stale idle data never shows infinity")
        battery.osBatteryCurrent = .nan
        battery.powerSampleTime = 250
        check(estimator.update(battery, target: 80, now: 250) == .estimating, "nonfinite current rejected")
        battery.osBatteryCurrent = 1
        battery.batteryPercentage = 70
        battery.isCharging = true
        battery.fullChargeCapacityMAh = nil
        check(estimator.update(battery, target: 80, now: 250) == .estimating, "missing capacity has no numeric estimate")
        battery.fullChargeCapacityMAh = 5000
        check(estimator.update(battery, target: 101, now: 250) == .estimating, "invalid target rejected")
        battery.batteryPercentage = 80
        check(estimator.update(battery, target: 80, now: 250) != .holding(80), "charging at rounded target is not holding")
        battery.batteryPercentage = 70
        _ = estimator.update(battery, target: 80, now: 250)
        battery.powerSampleTime = 400
        check(estimator.update(battery, target: 80, now: 400) == .estimating, "long sample gap requires new warmup")
        check(TargetTimeEstimate.holding(80).text == "∞ · Holding at 80%", "holding label is explicit")
        check(TargetTimeEstimate.minutes(18, target: 80).text == "≈ 18 min to 80%", "ETA is labeled approximate and names target")
        exit(failures == 0 ? 0 : 1)
    }
}
