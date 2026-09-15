import Foundation

@main struct FirmwareTests {
    static func main() throws {
        func require(_ condition: Bool, _ message: String) {
            guard condition else { print("FAIL: \(message)"); exit(1) }
            print("PASS: \(message)")
        }
        var registers: [FirmwareChargeKey: Data] = [.activation: Data([2]), .upper: Data([80,0,0,0]), .lower: Data([75,0,0,0])]
        let original = try FirmwareChargeLimit.read { registers[$0, default: Data()] }
        require(original.upper == 80 && original.lower == 75 && original.active, "decode little-endian firmware state")
        var operations: [FirmwareChargeKey] = []
        let newLimit = try FirmwareChargeLimit(lower: 70, upper: 80)
        try newLimit.apply(read: { registers[$0, default: Data()] }, write: { operations.append($0); registers[$0] = $1 })
        require(operations == [.activation, .upper, .lower, .activation], "required firmware write order")
        require(registers[.lower] == Data([70,0,0,0]) && registers[.activation] == Data([2]), "exact threshold encoding and activation")
        operations = []
        try newLimit.apply(read: { registers[$0, default: Data()] }, write: { operations.append($0); registers[$0] = $1 })
        require(operations.isEmpty, "unchanged target performs no writes")
        for limits in [(-1,80), (80,80), (90,80), (75,101)] {
            do { _ = try FirmwareChargeLimit(lower: limits.0, upper: limits.1); require(false,"invalid limits") }
            catch { require(true,"invalid limits rejected") }
        }
        enum Injected: Error { case writeFailed }
        var failOnce = true
        do {
            try original.apply(read: { registers[$0, default: Data()] }, write: { key, value in
                if key == .lower && failOnce { failOnce = false; throw Injected.writeFailed }
                registers[key] = value
            })
            require(false, "failed update must throw")
        } catch {
            require(try FirmwareChargeLimit.read { registers[$0, default: Data()] } == newLimit, "failed update restores previous firmware state")
        }
        do {
            _ = try FirmwareChargeLimit.read { key in key == .upper ? Data([80]) : registers[key, default: Data()] }
            require(false, "malformed firmware must throw")
        } catch { require(true,"unexpected register size rejected") }
    }
}
