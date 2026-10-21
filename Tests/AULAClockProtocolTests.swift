import Foundation

@main
struct AULAClockProtocolTests {
    static func main() throws {
        let iso = ISO8601DateFormatter()
        func check(_ condition: Bool, _ message: String = "Assertion failed") { precondition(condition, message) }
        func plan(_ stamp: String, _ zone: String = "Europe/Bucharest") throws -> AULAClockProtocol.Plan {
            try AULAClockProtocol.plan(date: iso.date(from: stamp)!, timezone: zone)
        }
        func reject(_ code: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure("Expected \(code)") }
            catch { check((error as? AULAClockProtocol.Failure)?.code == code, "Unexpected error: \(error)") }
        }
        let p = try plan("2026-10-13T12:34:56Z")
        check(p.timestamp == "2026-10-13T15:34:56+03:00")
        check(p.packets.count == 4 && p.packets.allSatisfy { $0.count == 64 })
        check(p.packets[0][0...1] == [0x04, 0x18])
        check(p.packets[1][0...1] == [0x04, 0x28] && p.packets[1][8] == 1)
        check(p.packets[3][0...1] == [0x04, 0x02])
        let data = p.packets[2]
        check(Array(data[0...10]) == [0, 1, 0x5A, 26, 10, 13, 15, 34, 56, 0, 2])
        check(data[11..<62].allSatisfy { $0 == 0 } && data[62] == 0x55 && data[63] == 0xAA)
        check(p.packets.allSatisfy { !($0[0] == 4 && [0xF0, 0x72, 0x13, 0x11, 0x27].contains($0[1])) })
        check(try plan("2000-01-01T00:00:00Z", "Etc/UTC").packets[2][3] == 0)
        check(try plan("2099-12-31T23:59:59Z", "Etc/UTC").packets[2][3] == 99)
        check(try plan("2024-02-29T23:30:00Z").packets[2][4...6] == [3, 1, 1])
        check(try plan("2026-10-25T00:30:00Z").timestamp == "2026-10-25T03:30:00+03:00")
        check(try plan("2026-10-25T01:30:00Z").timestamp == "2026-10-25T03:30:00+02:00")
        check(try plan("2026-10-18T12:00:00Z").packets[2][10] == 0)
        reject("UNSUPPORTED_DATE") { _ = try plan("1999-12-31T23:59:59Z", "Etc/UTC") }
        reject("UNSUPPORTED_DATE") { _ = try plan("2100-01-01T00:00:00Z", "Etc/UTC") }
        reject("INVALID_TIME") { _ = try plan("2026-10-13T12:00:00Z", "not/a/timezone") }
        reject("INVALID_TIME") { _ = try AULAClockProtocol.plan(date: Date(timeIntervalSince1970: .infinity), timezone: "Etc/UTC") }
        check(try AULAClockProtocol.parse(["Dial", "--other"]) == nil)
        check(try AULAClockProtocol.parse(["Dial", "--aula-clock", "status"]) == .status)
        check(try AULAClockProtocol.parse(["Dial", "--aula-clock", "sync", "--timezone", "Europe/Bucharest"]) == .sync(timezone: "Europe/Bucharest"))
        check(try AULAClockProtocol.parse(["Dial", "--aula-clock", "sync", "--timezone", "Europe/Bucharest", "--device", "12345"]) == .sync(timezone: "Europe/Bucharest", device: 12345))
        for id in ["0", "-1", "0x123", "", "18446744073709551616", "123oops", "+123"] {
            reject("INVALID_ARGUMENTS") { _ = try AULAClockProtocol.parse(["Dial", "--aula-clock", "sync", "--timezone", "Europe/Bucharest", "--device", id]) }
        }
        reject("INVALID_ARGUMENTS") { _ = try AULAClockProtocol.parse(["Dial", "--aula-clock", "sync"]) }
        reject("INVALID_ARGUMENTS") { _ = try AULAClockProtocol.parse(["Dial", "--aula-clock", "status", "--extra"]) }
        reject("INVALID_ARGUMENTS") { _ = try AULAClockProtocol.parse(["Dial", "--aula-clock", "sync", "--timezone", "invalid"]) }
        reject("NEEDS_WIRED") { try AULAClockProtocol.requireSingleDevice(0) }
        reject("AMBIGUOUS_DEVICE") { try AULAClockProtocol.requireSingleDevice(2) }
        try AULAClockProtocol.requireSingleDevice(1)
        check(try AULAClockProtocol.selectedIndex(registryIDs: [100], selector: nil) == 0)
        check(try AULAClockProtocol.selectedIndex(registryIDs: [100, 200], selector: 200) == 1)
        check(try AULAClockProtocol.selectedIndex(registryIDs: [100, 200], selector: 100) == 0)
        reject("AMBIGUOUS_DEVICE") { _ = try AULAClockProtocol.selectedIndex(registryIDs: [100, 200], selector: nil) }
        reject("NEEDS_WIRED") { _ = try AULAClockProtocol.selectedIndex(registryIDs: [], selector: nil) }
        reject("DEVICE_SELECTION_FAILED") { _ = try AULAClockProtocol.selectedIndex(registryIDs: [100], selector: 200) }
        reject("DEVICE_SELECTION_FAILED") { _ = try AULAClockProtocol.selectedIndex(registryIDs: [], selector: 200) }
        reject("DEVICE_SELECTION_FAILED") { _ = try AULAClockProtocol.selectedIndex(registryIDs: [100, 100], selector: 100) }
        for packet in [p.packets[0], p.packets[1], p.packets[3]] {
            var ack = packet; ack[3] = 1
            try AULAClockProtocol.validateResponse(ack, sent: packet)
            ack[3] = 0
            reject("MISSING_ACK") { try AULAClockProtocol.validateResponse(ack, sent: packet) }
            ack[3] = 1; ack[1] = 0xFF
            reject("MISSING_ACK") { try AULAClockProtocol.validateResponse(ack, sent: packet) }
        }
        try AULAClockProtocol.validateResponse(data, sent: data)
        var wrongEcho = data; wrongEcho[62] = 0xAA
        reject("INVALID_ECHO") { try AULAClockProtocol.validateResponse(wrongEcho, sent: data) }
        reject("INVALID_RESPONSE") { try AULAClockProtocol.validateResponse(Array(data.prefix(63)), sent: data) }
        print("AULA clock pure protocol checks passed (no device access)")
    }
}
