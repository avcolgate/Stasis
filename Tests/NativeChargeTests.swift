import Foundation

final class FakeNativeBackend: NativeChargeBackend {
    var limits = [80, 85, 90, 95, 100]
    var limit = 80
    var writes = [Int]()
    var fail = false
    func readLimit() throws -> Int { limit }
    func writeLimit(_ value: Int) throws {
        if fail { throw NativeChargeError.failed("test failure") }
        writes.append(value); limit = value
    }
}

@main struct NativeChargeTests {
    static func main() throws {
        assert(PowerUIChargeBackend.acceptsState(enabled: false, limit: 100))
        assert(!PowerUIChargeBackend.acceptsState(enabled: false, limit: 80))
        print("PASS: native 100 percent is a recoverable unlimited state")
        if CommandLine.arguments.contains("--hardware-read") {
            let hardware = try PowerUIChargeBackend()
            print("Native limits: \(hardware.limits); current: \(try hardware.readLimit())")
            return
        }
        let name = "Stasis-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = FakeNativeBackend()
        let controller = NativeChargeSession(backend: backend, defaults: defaults)
        try controller.apply(85)
        assert(backend.limit == 85)
        try controller.apply(100)
        try controller.apply(85)
        assert(backend.limit == 85)
        try controller.restore()
        assert(backend.limit == 80)
        print("PASS: native limit and override restore original")
        do { try controller.apply(75); fatalError("accepted unsupported limit") }
        catch NativeChargeError.unsupportedLimit { }
        assert(backend.limit == 80)
        print("PASS: native unsupported limit rejected")
        try controller.apply(100)
        let recovered = NativeChargeSession(backend: backend, defaults: defaults)
        try recovered.restore()
        assert(backend.limit == 80)
        print("PASS: native recovery survives controller restart")
        try controller.apply(100)
        backend.fail = true
        do { try controller.restore(); fatalError("ignored failure") } catch { }
        backend.fail = false
        try NativeChargeSession(backend: backend, defaults: defaults).restore()
        assert(backend.limit == 80)
        print("PASS: failed restoration retains recovery record")
    }
}
