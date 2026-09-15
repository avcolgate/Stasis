enum PowerSource: Codable {
    case battery
    case acAdapter
    case both

    static func current(battery: BatteryMetrics, adapter: AdapterMetrics) -> Self {
        guard battery.externalConnected else { return .battery }
        if ChargingMode.current(battery: battery) == .discharging {
            return adapter.adapterPower > 0.5 ? .both : .battery
        }
        return .acAdapter
    }
}
