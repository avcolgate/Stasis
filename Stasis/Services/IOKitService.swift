import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os.log

@MainActor
class IOKitService {
    private var notificationPort: IONotificationPortRef?
    private var interestNotification: io_object_t = 0
    private var batteryService: io_service_t = 0
    private var healthTask: Task<Void, Never>?
    private var reportedHealth: Int?

    private var continuation: AsyncStream<(BatteryMetrics, AdapterMetrics)>.Continuation?

    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "IOKitService"
    )

    func metricsStream() -> AsyncStream<(BatteryMetrics, AdapterMetrics)> {
        AsyncStream { continuation in
            self.continuation = continuation

            continuation.onTermination = { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                }
            }

            self.startNotifications()
            self.startHealthRefresh()
        }
    }

    private func startNotifications() {
        logger.info("Starting IOKit monitoring")

        batteryService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        if batteryService == 0 {
            logger.error("Failed to get AppleSmartBattery service")
        }

        guard batteryService != 0 else { return }

        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notificationPort else {
            logger.error("Failed to create IONotificationPort")
            return
        }

        let notificationSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), notificationSource, .commonModes)

        let context = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(self).toOpaque()
        )

        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            let monitor = Unmanaged<IOKitService>.fromOpaque(refcon)
                .takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.emitMetrics()
            }
        }

        let result = IOServiceAddInterestNotification(
            notificationPort,
            batteryService,
            kIOGeneralInterest,
            callback,
            context,
            &interestNotification
        )

        if result == KERN_SUCCESS {
            logger.info("IORegistry interest notification registered for AppleSmartBattery")
        } else {
            logger.error("Failed to register interest notification: \(result)")
        }

        emitMetrics()
    }

    private func stop() {
        healthTask?.cancel()
        healthTask = nil
        if interestNotification != 0 {
            IOObjectRelease(interestNotification)
            interestNotification = 0
        }
        if let notificationPort {
            let source = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if batteryService != 0 {
            IOObjectRelease(batteryService)
            batteryService = 0
        }
        continuation = nil
    }

    private func emitMetrics() {
        logger.debug("IOKit notification triggered")

        let powerInfo = getPowerSourceInfo() as? [String: Any]
        var batteryMetrics = BatteryMetrics()
        var adapterMetrics = AdapterMetrics()

        let percentages = getBatteryPercentages(powerInfo: powerInfo)
        batteryMetrics.batteryPercentage = percentages.displayed
        batteryMetrics.hardwareBatteryPercentage = percentages.hardware

        batteryMetrics.hasPowerSourceData = powerInfo?[kIOPSIsChargingKey] as? Bool != nil
        batteryMetrics.isCharging = powerInfo?[kIOPSIsChargingKey] as? Bool ?? false
        if batteryMetrics.isCharging {
            batteryMetrics.timeRemaining = getTimeToFull(powerInfo: powerInfo) ?? -1
        } else {
            batteryMetrics.timeRemaining = getTimeRemaining(powerInfo: powerInfo) ?? -1
        }

        batteryMetrics.batteryHealth = reportedHealth ?? BatteryReading.estimatedHealth(from: batteryProperties())
        batteryMetrics.batteryHealthIsEstimated = reportedHealth == nil

        batteryMetrics.externalConnected =
            getPropertyValue(batteryService, key: "ExternalConnected") ?? false

        let properties = batteryProperties()
        if let current = (properties["InstantAmperage"] ?? properties["Amperage"]) as? NSNumber,
           let voltage = properties["Voltage"] as? NSNumber {
            batteryMetrics.osBatteryCurrent = BatteryReading.signedAmperage(current)
            batteryMetrics.batteryCurrent = BatteryReading.signedAmperage(current)
            batteryMetrics.batteryVoltage = voltage.doubleValue / 1000
            batteryMetrics.batteryPower = batteryMetrics.batteryCurrent * batteryMetrics.batteryVoltage
        }

        adapterMetrics.adapterConnected = isAdapterConnected()

        if let temp = getBatteryTemperature(powerInfo: powerInfo) {
            batteryMetrics.batteryTemperature = temp
        }

        batteryMetrics.cycleCount =
            getPropertyValue(batteryService, key: "CycleCount") ?? 0

        logger.debug(
            "IOKit metrics: battery=\(batteryMetrics.batteryPercentage)%, hardwareBattery=\(batteryMetrics.hardwareBatteryPercentage)%, health=\(batteryMetrics.batteryHealth.map(String.init) ?? "unknown")%, charging=\(batteryMetrics.isCharging), temp=\(batteryMetrics.batteryTemperature)°C, cycles=\(batteryMetrics.cycleCount), timeRemaining=\(batteryMetrics.timeRemaining), externalConnected=\(batteryMetrics.externalConnected), adapterConnected=\(adapterMetrics.adapterConnected)"
        )

        continuation?.yield((batteryMetrics, adapterMetrics))
    }

    private nonisolated func getPowerSourceInfo() -> CFDictionary? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources =
            IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        guard let source = sources.first else { return nil }
        return IOPSGetPowerSourceDescription(snapshot, source)
            .takeUnretainedValue()
    }

    private nonisolated func getPropertyValue<T>(_ service: io_service_t, key: String) -> T? {
        guard
            let prop = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )
        else {
            return nil
        }
        return prop.takeRetainedValue() as? T
    }

    private func getBatteryPercentages(powerInfo: [String: Any]?) -> (
        displayed: Int, hardware: Int
    ) {
        let displayedPercent = powerInfo?[kIOPSCurrentCapacityKey] as? Int ?? 0

        let capacities = BatteryReading.capacities(from: batteryProperties())
        let hardwarePercent: Int
        if let current = capacities.current, let maximum = capacities.maximum {
            hardwarePercent = min(100, max(0, Int(Double(current) * 100 / Double(maximum))))
        } else {
            hardwarePercent = displayedPercent
        }

        return (displayedPercent, hardwarePercent)
    }

    private func getTimeRemaining(powerInfo: [String: Any]?) -> Int? {
        guard let timeToEmpty = powerInfo?[kIOPSTimeToEmptyKey] as? Int,
              timeToEmpty > 0,
              timeToEmpty != Int(kIOPSTimeRemainingUnknown) else {
            return nil
        }

        return timeToEmpty
    }

    private func getTimeToFull(powerInfo: [String: Any]?) -> Int? {
        guard let timeToFull = powerInfo?[kIOPSTimeToFullChargeKey] as? Int,
              timeToFull > 0,
              timeToFull != Int(kIOPSTimeRemainingUnknown) else {
            return nil
        }

        return timeToFull
    }

    private func isAdapterConnected() -> Bool {
        guard let adapterDetails: [String: Any] = getPropertyValue(batteryService, key: "AdapterDetails"),
              let watts = adapterDetails["Watts"] as? Int else {
            return false
        }

        return watts > 0
    }

    private func getBatteryTemperature(powerInfo: [String: Any]?) -> Double? {
        if let powerInfo,
            let temp = powerInfo[kIOPSTemperatureKey] as? Int,
            temp > 0
        {
            return decikelvinToCelsius(temp)
        }

        guard
            let temp: Int = getPropertyValue(
                batteryService,
                key: "Temperature"
            ),
            temp > 0, temp <= 5000
        else {
            return nil
        }

        return decikelvinToCelsius(temp)
    }

    private nonisolated func decikelvinToCelsius(_ decikelvin: Int) -> Double? {
        let celsius = (Double(decikelvin) / 10.0) - 273.15
        return (0...80).contains(celsius) ? celsius : nil
    }

    private func batteryProperties() -> [String: Any] {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(batteryService, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties else { return [:] }
        return properties.takeRetainedValue() as NSDictionary as? [String: Any] ?? [:]
    }

    private func startHealthRefresh() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                let health = await Task.detached(priority: .utility) {
                    let process = Process()
                    let output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
                    process.arguments = ["SPPowerDataType", "-json", "-timeout", "10"]
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    do {
                        try process.run()
                        let data = output.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        guard process.terminationStatus == 0 else { return Optional<Int>.none }
                        return BatteryReading.reportedHealth(from: data)
                    } catch { return nil }
                }.value
                guard !Task.isCancelled, let self else { return }
                self.reportedHealth = health
                self.logger.info("Apple-reported battery health: \(health.map(String.init) ?? "unavailable", privacy: .public)")
                self.emitMetrics()
                do { try await Task.sleep(for: .seconds(1800)) } catch { return }
            }
        }
    }
}
