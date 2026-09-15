enum ChargingMode {
    case charging
    case discharging
    case pluggedIn

    static func current(battery: BatteryMetrics) -> Self {
        // Wattage is only polled while the menu is open; IOKit supplies live power state.
        guard battery.externalConnected else { return .discharging }
        if battery.isCharging { return .charging }
        if let current = battery.osBatteryCurrent, current < -0.05 { return .discharging }
        return .pluggedIn
    }
}
