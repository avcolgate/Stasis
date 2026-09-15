import Foundation

public enum FirmwareChargeKey: Sendable { case activation, upper, lower }

public struct FirmwareChargeLimit: Equatable, Sendable {
    public let active: Bool
    public let lower: Int
    public let upper: Int

    public init(active: Bool = true, lower: Int, upper: Int) throws {
        guard lower >= 0, upper <= 100, lower < upper else { throw FirmwareChargeError.invalidLimits }
        self.active = active
        self.lower = lower
        self.upper = upper
    }

    public static func read(using read: (FirmwareChargeKey) throws -> Data) throws -> Self {
        let activation = try read(.activation)
        guard activation.count == 1, activation[0] == 0 || activation[0] == 2 else {
            throw FirmwareChargeError.invalidData
        }
        func percentage(_ key: FirmwareChargeKey) throws -> Int {
            let bytes = try read(key)
            guard bytes.count == 4 else { throw FirmwareChargeError.invalidData }
            return bytes.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
        }
        return try Self(active: activation[0] == 2, lower: percentage(.lower), upper: percentage(.upper))
    }

    // macOS 27 firmware requires disable → upper → lower → activate.
    // These particular ui32 fields are little-endian, unlike conventional SMC ui32 values.
    public func write(using write: (FirmwareChargeKey, Data) throws -> Void) throws {
        func encoded(_ value: Int) -> Data {
            Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) })
        }
        try write(.activation, Data([0]))
        try write(.upper, encoded(upper))
        try write(.lower, encoded(lower))
        try write(.activation, Data([active ? 2 : 0]))
    }

    public func apply(read: (FirmwareChargeKey) throws -> Data,
                      write: (FirmwareChargeKey, Data) throws -> Void) throws {
        let previous = try Self.read(using: read)
        guard previous != self else { return }
        do {
            try self.write(using: write)
            guard try Self.read(using: read) == self else { throw FirmwareChargeError.verificationFailed }
        } catch {
            do {
                try previous.write(using: write)
                guard try Self.read(using: read) == previous else { throw FirmwareChargeError.restorationFailed }
            }
            catch { throw FirmwareChargeError.restorationFailed }
            throw error
        }
    }
}

public enum FirmwareChargeError: LocalizedError {
    case invalidLimits, invalidData, verificationFailed, restorationFailed
    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "Invalid firmware charging thresholds."
        case .invalidData: "The firmware returned an unrecognized charging-limit format."
        case .verificationFailed: "The firmware did not retain the requested charging limit."
        case .restorationFailed: "The charging-limit update failed and the previous limit could not be restored. Check System Settings → Battery."
        }
    }
}
