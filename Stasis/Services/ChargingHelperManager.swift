import Foundation
import ServiceManagement
import os.log

enum ChargingHelperStatus {
    case notInstalled
    case requiresApproval
    case installed
}

@MainActor
@Observable
class ChargingHelperManager {
    static let shared = ChargingHelperManager()

    private static let machServiceName = "com.srimanachanta.stasis.charging-helper"
    private static let plistName = "com.srimanachanta.stasis.charging-helper.plist"

    private let service: SMAppService
    private var connection: NSXPCConnection?
    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "ChargingHelperManager"
    )

    private(set) var helperStatus: ChargingHelperStatus
    private(set) var firmwareChargeControl = false
    private(set) var firmwareProbeError: String?

    var isInstalled: Bool {
        service.status == .enabled
    }

    private init() {
        service = SMAppService.daemon(plistName: Self.plistName)
        switch service.status {
        case .enabled: helperStatus = .installed
        case .requiresApproval: helperStatus = .requiresApproval
        default: helperStatus = .notInstalled
        }
    }

    func install() throws {
        logger.info("Registering charging helper daemon")

        do {
            try service.register()
        } catch {
            // register() commonly throws "Operation not permitted" while macOS
            // processes the background item notification, even though the
            // registration advanced to requiresApproval or enabled.
            if service.status != .enabled && service.status != .requiresApproval {
                throw error
            }
        }

        refreshStatus()
    }

    func uninstall() throws {
        logger.info("Unregistering charging helper daemon")
        disconnect()
        try service.unregister()
        helperStatus = .notInstalled
        firmwareChargeControl = false
    }

    func refreshStatus() {
        switch service.status {
        case .enabled: helperStatus = .installed
        case .requiresApproval: helperStatus = .requiresApproval
        default: helperStatus = .notInstalled
        }
    }

    func refreshFirmwareSupport() async {
        guard isInstalled else { return }
        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            let request = FirmwareCapabilityRequest(continuation)
            guard let helper = getHelper(errorHandler: { error in
                Task { @MainActor in request.finish(false, error.localizedDescription) }
            }) else {
                request.finish(false, "Charging helper is unavailable.")
                return
            }
            helper.getFirmwareChargeControl { supported, message in
                Task { @MainActor in request.finish(supported, message) }
            }
            Task {
                try? await Task.sleep(for: .seconds(10))
                request.finish(false, "Charging helper did not respond. Check Login Items in System Settings.")
            }
        }
        firmwareChargeControl = result.0
        firmwareProbeError = result.1
    }

    func getHelper(errorHandler: @escaping @Sendable (Error) -> Void) -> ChargingHelperProtocol? {
        if connection == nil {
            connect()
        }
        guard let connection else { return nil }
        return connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? ChargingHelperProtocol
    }

    private func connect() {
        logger.info("Setting up XPC connection to charging helper daemon")
        let newConnection = NSXPCConnection(
            machServiceName: Self.machServiceName
        )
        newConnection.remoteObjectInterface = NSXPCInterface(
            with: ChargingHelperProtocol.self
        )

        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logger.warning("Charging helper XPC connection invalidated")
                self.connection = nil
            }
        }

        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logger.warning("Charging helper XPC connection interrupted")
                self.connection = nil
            }
        }

        newConnection.resume()
        connection = newConnection
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }
}

@MainActor
private final class FirmwareCapabilityRequest {
    private var continuation: CheckedContinuation<(Bool, String?), Never>?
    init(_ continuation: CheckedContinuation<(Bool, String?), Never>) { self.continuation = continuation }
    func finish(_ supported: Bool, _ error: String?) {
        continuation?.resume(returning: (supported, error))
        continuation = nil
    }
}
