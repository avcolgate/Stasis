import Foundation

struct BatteryMetrics: Codable, Equatable {
    var batteryPercentage: Int = 0
    var hardwareBatteryPercentage: Int = 0
    var isCharging: Bool = false
    var timeRemaining: Int = 0

    var batteryVoltage: Double = 0
    var batteryCurrent: Double = 0
    var osBatteryCurrent: Double?
    var fullChargeCapacityMAh: Double?
    var powerSampleTime: Double?
    var batteryPower: Double = 0
    var batteryTemperature: Double = 0

    var batteryHealth: Int?
    var batteryHealthIsEstimated = false
    var hasPowerSourceData = false
    var cycleCount: Int = 0

    var externalConnected: Bool = false
}

struct AdapterMetrics: Equatable {
    var adapterConnected: Bool = false
    var adapterVoltage: Double = 0
    var adapterCurrent: Double = 0
    var adapterPower: Double = 0
}

struct BatteryControlState: Equatable {
    var batteryPercentage: Int = 0
    var hardwareBatteryPercentage: Int = 0
    var adapterConnected: Bool = false
    var batteryTemperature: Double = 0
}

enum TemperatureLevel {
    case normal, warm, hot

    private static let warningMargin = 5.0

    init(temperature: Double, limit: Int) {
        let limit = Double(limit)
        if temperature <= 0 {
            self = .normal
        } else if temperature >= limit {
            self = .hot
        } else if temperature >= limit - Self.warningMargin {
            self = .warm
        } else {
            self = .normal
        }
    }
}
