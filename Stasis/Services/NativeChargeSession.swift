import Foundation
import ObjectiveC

enum NativeChargeError: LocalizedError {
    case unavailable, unsupportedLimit, failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Native charge control is unavailable."
        case .unsupportedLimit: "This charge limit is not supported by macOS."
        case .failed(let message): message
        }
    }
}

protocol NativeChargeBackend: AnyObject {
    var limits: [Int] { get }
    func readLimit() throws -> Int
    func writeLimit(_ value: Int) throws
}

/// Journal before writing: a failed restore can be retried on the next launch.
final class NativeChargeSession {
    private let backend: NativeChargeBackend
    private let defaults: UserDefaults
    private let recoveryKey = "nativeChargeOriginalLimit"
    init(backend: NativeChargeBackend, defaults: UserDefaults = .standard) {
        self.backend = backend
        self.defaults = defaults
    }
    func apply(_ limit: Int) throws {
        guard backend.limits.contains(limit) else { throw NativeChargeError.unsupportedLimit }
        let current = try backend.readLimit()
        if defaults.object(forKey: recoveryKey) == nil {
            defaults.set(current, forKey: recoveryKey)
            defaults.synchronize()
        }
        if current != limit { try backend.writeLimit(limit) }
        guard try backend.readLimit() == limit else {
            throw NativeChargeError.failed("macOS did not retain the requested charge limit.")
        }
    }
    func restore() throws {
        guard defaults.object(forKey: recoveryKey) != nil else { return }
        let original = defaults.integer(forKey: recoveryKey)
        try backend.writeLimit(original)
        guard try backend.readLimit() == original else {
            throw NativeChargeError.failed("Could not restore the previous charge limit. Check System Settings → Battery.")
        }
        defaults.removeObject(forKey: recoveryKey)
        defaults.synchronize()
    }
}

/// Private API: fail closed when the class, selectors or advertised limits differ.
final class PowerUIChargeBackend: NativeChargeBackend {
    private let client: NSObject
    let limits: [Int]
    private typealias ErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>?
    static func acceptsState(enabled: Bool, limit: Int) -> Bool {
        enabled || limit == 100
    }

    init() throws {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else {
            throw NativeChargeError.unavailable
        }
        let alloc = NSSelectorFromString("alloc")
        typealias Allocate = @convention(c) (AnyObject, Selector) -> AnyObject
        guard let allocation = class_getClassMethod(cls, alloc) else { throw NativeChargeError.unavailable }
        let object = unsafeBitCast(method_getImplementation(allocation), to: Allocate.self)(cls, alloc)
        let initialize = NSSelectorFromString("initWithClientName:")
        guard let method = class_getInstanceMethod(cls, initialize) else { throw NativeChargeError.unavailable }
        typealias Initialize = @convention(c) (AnyObject, Selector, NSString) -> AnyObject
        guard let initialized = unsafeBitCast(method_getImplementation(method), to: Initialize.self)(object, initialize, "Stasis") as? NSObject else { throw NativeChargeError.unavailable }
        client = initialized
        for name in ["isMCLSupported", "isMCLCurrentlyEnabled:", "getMCLLimitWithError:", "availableChargeLimitsWithError:", "setMCLLimit:error:"] {
            guard client.responds(to: NSSelectorFromString(name)) else { throw NativeChargeError.unavailable }
        }
        let supported = NSSelectorFromString("isMCLSupported")
        typealias Supported = @convention(c) (AnyObject, Selector) -> Bool
        guard unsafeBitCast(client.method(for: supported), to: Supported.self)(client, supported) else { throw NativeChargeError.unavailable }
        // macOS represents a 100% target as disabled; it must remain recoverable.
        let enabled = NSSelectorFromString("isMCLCurrentlyEnabled:")
        typealias Enabled = @convention(c) (AnyObject, Selector, ErrorPointer) -> UInt
        var error: NSError?
        let enabledState = unsafeBitCast(client.method(for: enabled), to: Enabled.self)(client, enabled, &error)
        guard error == nil else { throw NativeChargeError.unavailable }
        let available = NSSelectorFromString("availableChargeLimitsWithError:")
        typealias Available = @convention(c) (AnyObject, Selector, ErrorPointer) -> Unmanaged<AnyObject>?
        let values = unsafeBitCast(client.method(for: available), to: Available.self)(client, available, &error)?.takeUnretainedValue() as? [NSNumber]
        guard error == nil, let values else { throw NativeChargeError.unavailable }
        limits = values.map(\.intValue).filter { (80...100).contains($0) }.sorted()
        guard limits.contains(80), limits.contains(100) else { throw NativeChargeError.unavailable }
        guard Self.acceptsState(enabled: enabledState == 1, limit: try readLimit()) else { throw NativeChargeError.unavailable }
    }

    func readLimit() throws -> Int {
        let selector = NSSelectorFromString("getMCLLimitWithError:")
        typealias Read = @convention(c) (AnyObject, Selector, ErrorPointer) -> UInt8
        var error: NSError?
        let result = unsafeBitCast(client.method(for: selector), to: Read.self)(client, selector, &error)
        if let error { throw error }
        guard limits.contains(Int(result)) else { throw NativeChargeError.unsupportedLimit }
        return Int(result)
    }

    func writeLimit(_ value: Int) throws {
        guard limits.contains(value) else { throw NativeChargeError.unsupportedLimit }
        let selector = NSSelectorFromString("setMCLLimit:error:")
        typealias Write = @convention(c) (AnyObject, Selector, UInt8, ErrorPointer) -> Bool
        var error: NSError?
        let success = unsafeBitCast(client.method(for: selector), to: Write.self)(client, selector, UInt8(value), &error)
        if let error { throw error }
        guard success else { throw NativeChargeError.failed("macOS rejected the charge-limit update.") }
    }
}
