import Defaults
import Foundation
import IOKit.pwr_mgt
import Observation
import os.log
import smc_power

@MainActor
@Observable
class ChargeManager {
    static let nativeBackend: PowerUIChargeBackend? = {
        do {
            return try PowerUIChargeBackend()
        } catch {
            Logger(subsystem: "com.srimanachanta.stasis", category: "ChargeManager")
                .warning("Native charge control unavailable: \(error, privacy: .public)")
            return nil
        }
    }()
    private let nativeSession: NativeChargeSession?
    var usesNativeControl: Bool { nativeSession != nil }
    var canForceDischarge: Bool {
        !usesNativeControl && batteryService.deviceCapabilities.chargingControl
            && batteryService.deviceCapabilities.adapterControl
            && !batteryService.deviceCapabilities.firmwareChargeControl
            && !ChargingHelperManager.shared.firmwareChargeControl
    }
    private let batteryService: BatteryService

    private var metricsObservation: Task<Void, Never>?
    private var settingsObservation: Task<Void, Never>?

    private var lastAdapterConnected: Bool?
    private var lastManageChargingEnabled: Bool?
    private var firmwareLimitTask: Task<Void, Never>?
    private var appliedFirmwareLimit: FirmwareChargeLimit?
    private var hasReachedChargeLimit = false

    private(set) var chargeLimitOverrideActive = false
    private(set) var forceDischargeActive = false
    private var sleepAssertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "ChargeManager"
    )

    init(batteryService: BatteryService) {
        self.batteryService = batteryService
        nativeSession = Self.nativeBackend.map { NativeChargeSession(backend: $0) }
        do { try nativeSession?.restore() }
        catch { Defaults[.chargingControlError] = error.localizedDescription }
        startObservingMetrics()
        startObservingSettings()
    }

    private func startObservingMetrics() {
        metricsObservation = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.evaluate(controlState: self.batteryService.controlState)
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.batteryService.controlState
                    } onChange: {
                        Task { @MainActor in
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    private func startObservingSettings() {
        settingsObservation = Task { [weak self] in
            for await _ in Defaults.updates(
                [
                    .manageCharging, .sailingMode, .automaticDischarge,
                    .disableSleepUntilChargeLimit,
                    .enableHeatProtectionMode, .manageMagSafeLED, .useHardwarePercentage,
                    .chargeLimit, .sailingModeLimit, .heatProtectionLimit,
                    .heatProtectionMagSafeLEDState,
                ],
                initial: false
            ) {
                guard let self else { return }
                self.evaluate(controlState: self.batteryService.controlState)
            }
        }
    }

    private func evaluate(controlState: BatteryControlState) {
        var stateWasCleared = false

        if controlState.adapterConnected != lastAdapterConnected {
            logger.info("Adapter connection changed: \(controlState.adapterConnected)")
            lastAdapterConnected = controlState.adapterConnected
            if !controlState.adapterConnected {
                chargeLimitOverrideActive = false
                forceDischargeActive = false
            }
            clearCachedState()
            stateWasCleared = true
        }

        if let nativeSession {
            do {
                if Defaults[.manageCharging] {
                    if controlState.batteryPercentage >= 100 { chargeLimitOverrideActive = false }
                    try nativeSession.apply(chargeLimitOverrideActive ? 100 : Defaults[.chargeLimit])
                } else {
                    chargeLimitOverrideActive = false
                    try nativeSession.restore()
                }
                Defaults[.chargingControlError] = ""
            } catch {
                Defaults[.chargingControlError] = error.localizedDescription
                logger.error("Native charge limit failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        if batteryService.deviceCapabilities.firmwareChargeControl || ChargingHelperManager.shared.firmwareChargeControl {
            evaluateFirmwareLimit(controlState: controlState)
            return
        }

        guard Defaults[.manageCharging], batteryService.deviceCapabilities.chargingControl,
              controlState.adapterConnected else {
            if chargeLimitOverrideActive, !controlState.adapterConnected {
                chargeLimitOverrideActive = false
            }
            if forceDischargeActive, !controlState.adapterConnected {
                forceDischargeActive = false
            }
            resetToDefaults()
            return
        }

        if lastManageChargingEnabled != true {
            lastManageChargingEnabled = true
            clearCachedState()
            stateWasCleared = true
        }

        let chargeLimit = chargeLimitOverrideActive ? 100 : Defaults[.chargeLimit]
        let batteryPercentage =
            Defaults[.useHardwarePercentage]
            ? controlState.hardwareBatteryPercentage : controlState.batteryPercentage

        if stateWasCleared && Defaults[.sailingMode]
            && batteryPercentage >= chargeLimit - Defaults[.sailingModeLimit] {
            hasReachedChargeLimit = true
        }

        var desiredCharging: Bool?
        var desiredAdapter: Bool?
        var desiredLED: MagSafeLEDState?

        if batteryPercentage > chargeLimit {
            hasReachedChargeLimit = true
            desiredCharging = false
            desiredAdapter = Defaults[.automaticDischarge] ? false : true
            desiredLED = Defaults[.manageMagSafeLED] ? .green : nil
        } else if batteryPercentage == chargeLimit {
            hasReachedChargeLimit = true
            desiredCharging = false
            desiredAdapter = true
            desiredLED = Defaults[.manageMagSafeLED] ? .green : nil
        } else if Defaults[.sailingMode] {
            let sailingThreshold = chargeLimit - Defaults[.sailingModeLimit]
            let inSailingRange = batteryPercentage >= sailingThreshold

            if inSailingRange && hasReachedChargeLimit {
                desiredCharging = false
                desiredAdapter = true
                desiredLED = Defaults[.manageMagSafeLED] ? .green : nil
            } else {
                hasReachedChargeLimit = false
                desiredCharging = true
                desiredAdapter = true
                desiredLED = Defaults[.manageMagSafeLED] ? .orange : nil
            }
        } else {
            desiredCharging = true
            desiredAdapter = true
            desiredLED = Defaults[.manageMagSafeLED] ? .orange : nil
        }

        if Defaults[.enableHeatProtectionMode]
            && controlState.batteryTemperature > Double(Defaults[.heatProtectionLimit])
        {
            desiredCharging = false
            if Defaults[.manageMagSafeLED] {
                desiredLED = Defaults[.heatProtectionMagSafeLEDState]
            }
        }

        if forceDischargeActive {
            desiredCharging = false
            desiredAdapter = false
        }

        let capabilities = batteryService.deviceCapabilities

        if let desiredCharging, capabilities.chargingControl {
            setCharging(enabled: desiredCharging)
        }
        if let desiredAdapter, capabilities.adapterControl {
            setAdapter(enabled: desiredAdapter)
        }
        if let desiredLED, capabilities.hasMagSafe, capabilities.magsafeLEDControl {
            setLED(state: desiredLED)
        }

        let shouldPreventSleep = Defaults[.disableSleepUntilChargeLimit]
            && desiredCharging == true
        updateSleepAssertion(shouldPreventSleep: shouldPreventSleep)
    }

    private func evaluateFirmwareLimit(controlState: BatteryControlState) {
        guard Defaults[.manageCharging] else {
            appliedFirmwareLimit = nil
            return
        }
        guard controlState.adapterConnected, firmwareLimitTask == nil else { return }
        let upper = chargeLimitOverrideActive ? 100 : Defaults[.chargeLimit]
        let gap = Defaults[.sailingMode] ? max(1, Defaults[.sailingModeLimit]) : 1
        do {
            let target = try FirmwareChargeLimit(lower: max(0, upper - gap), upper: upper)
            guard target != appliedFirmwareLimit else { return }
            firmwareLimitTask = Task {
                defer { firmwareLimitTask = nil }
                do {
                    try await batteryService.setFirmwareChargeLimit(lower: target.lower, upper: target.upper)
                    appliedFirmwareLimit = target
                    Defaults[.chargingControlError] = ""
                    logger.info("Firmware charge thresholds applied: \(target.lower)...\(target.upper)%")
                } catch {
                    Defaults[.chargingControlError] = error.localizedDescription
                    logger.error("Firmware charge control failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Defaults[.chargingControlError] = error.localizedDescription
        }
    }

    private func clearCachedState() {
        hasReachedChargeLimit = false
    }

    private func resetToDefaults() {
        guard lastManageChargingEnabled == true else { return }
        hasReachedChargeLimit = false
        lastManageChargingEnabled = false
        updateSleepAssertion(shouldPreventSleep: false)
        guard ChargingHelperManager.shared.isInstalled else { return }
        let capabilities = batteryService.deviceCapabilities
        if capabilities.chargingControl {
            setCharging(enabled: true)
        }
        if capabilities.adapterControl {
            setAdapter(enabled: true)
        }
        if capabilities.hasMagSafe, capabilities.magsafeLEDControl {
            setLED(state: .reset)
        }
    }

    private func setCharging(enabled: Bool) {
        logger.info("Setting charging: \(enabled)")
        Task {
            do {
                try await batteryService.manageBatteryCharging(enabled: enabled)
                batteryService.scheduleSinglePoll()
            } catch {
                logger.error("Failed to set charging to \(enabled): \(error)")
            }
        }
    }

    private func setAdapter(enabled: Bool) {
        logger.info("Setting adapter: \(enabled)")
        Task {
            do {
                try await batteryService.manageExternalPower(enabled: enabled)
                batteryService.scheduleSinglePoll()
            } catch {
                logger.error("Failed to set adapter to \(enabled): \(error)")
            }
        }
    }

    private func setLED(state: MagSafeLEDState) {
        logger.info("Setting MagSafe LED: \(String(describing: state))")
        Task {
            do {
                try await batteryService.manageMagsafeLED(target: state)
            } catch {
                logger.error("Failed to set LED to \(String(describing: state)): \(error)")
            }
        }
    }

    private func updateSleepAssertion(shouldPreventSleep: Bool) {
        let assertionActive = sleepAssertionID != IOPMAssertionID(kIOPMNullAssertionID)

        if shouldPreventSleep && !assertionActive {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Stasis: Charging towards charge limit" as CFString,
                &sleepAssertionID
            )
            if result == kIOReturnSuccess {
                logger.info("Sleep assertion created")
            } else {
                logger.error("Failed to create sleep assertion: \(result)")
            }
        } else if !shouldPreventSleep && assertionActive {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
            logger.info("Sleep assertion released")
        }
    }

    func toggleChargeLimitOverride() {
        guard Defaults[.manageCharging], batteryService.controlState.adapterConnected else { return }
        let previousOverride = chargeLimitOverrideActive
        chargeLimitOverrideActive.toggle()
        evaluate(controlState: batteryService.controlState)
        if usesNativeControl && !Defaults[.chargingControlError].isEmpty {
            chargeLimitOverrideActive = previousOverride
        }
    }

    func toggleForceDischarge() {
        guard canForceDischarge else { return }
        forceDischargeActive.toggle()
        evaluate(controlState: batteryService.controlState)
    }

    func stop() {
        metricsObservation?.cancel()
        metricsObservation = nil
        settingsObservation?.cancel()
        settingsObservation = nil
        updateSleepAssertion(shouldPreventSleep: false)
    }

    func restoreNativeLimit() throws {
        try nativeSession?.restore()
    }
}
