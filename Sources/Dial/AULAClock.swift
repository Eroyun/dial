import Foundation
import IOKit
import IOKit.hid
import Darwin

// Clock-only protocol sources inspected at immutable revisions:
// https://github.com/parsiya/f108-pro/blob/f7782b02e254490d9c4ae063a8c27cae38be226f/pkg/aula/clock.go
// https://github.com/sarequl/aula-studio/blob/fa858e9165254a389fa8d478b64a4cd30d7bc92f/Sources/AulaKit/AulaDevice.swift
// Both clock implementations use 55 AA, despite conflicting generic trailer documentation.
// This path never opens the LCD pixel interface, sends images, or updates firmware.
enum AULAClockProtocol {
    static let vendorID = 0x0C45
    static let productID = 0x800A
    static let usagePage = 0xFF13
    static let usage = 1
    static let reportSize = 64
    static let commandDelay = 0.035
    static let wiredInstructions = "On the keyboard LCD, use the knob to select Connection Mode → Wired Mode, then insert a data-capable USB cable within five seconds."

    struct Failure: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? { message }
    }

    enum Request: Equatable {
        case status
        case sync(timezone: String, device: UInt64? = nil)
    }

    static func parse(_ arguments: [String]) throws -> Request? {
        guard arguments.dropFirst().contains("--aula-clock") else { return nil }
        let args = Array(arguments.dropFirst())
        if args == ["--aula-clock", "status"] { return .status }
        if (args.count == 4 || args.count == 6), args[0] == "--aula-clock", args[1] == "sync", args[2] == "--timezone",
           validTimezone(args[3]), TimeZone(identifier: args[3]) != nil {
            if args.count == 4 { return .sync(timezone: args[3]) }
            if args[4] == "--device", !args[5].isEmpty, args[5].allSatisfy({ $0.isASCII && $0.isNumber }),
               let device = UInt64(args[5]), device > 0 {
                return .sync(timezone: args[3], device: device)
            }
        }
        throw Failure(code: "INVALID_ARGUMENTS", message: "Use --aula-clock status or --aula-clock sync --timezone Europe/Bucharest [--device <registryID from status>]. A valid IANA timezone and positive decimal registryID are required.")
    }

    private static func validTimezone(_ identifier: String) -> Bool {
        TimeZone.knownTimeZoneIdentifiers.contains(identifier) || identifier == "Etc/UTC" || identifier == "UTC"
    }

    struct Plan {
        let packets: [[UInt8]]
        let timestamp: String
        let timezone: String
    }

    static func plan(date: Date, timezone identifier: String) throws -> Plan {
        guard date.timeIntervalSince1970.isFinite,
              validTimezone(identifier),
              let timezone = TimeZone(identifier: identifier) else {
            throw Failure(code: "INVALID_TIME", message: "A finite date and valid IANA timezone are required.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let c = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        guard c.era == 1, let year = c.year, (2000...2099).contains(year),
              let month = c.month, (1...12).contains(month),
              let day = c.day, (1...31).contains(day),
              let hour = c.hour, (0...23).contains(hour),
              let minute = c.minute, (0...59).contains(minute),
              let second = c.second, (0...59).contains(second),
              let weekday = c.weekday, (1...7).contains(weekday),
              c.isValidDate(in: calendar) else {
            throw Failure(code: "UNSUPPORTED_DATE", message: "The keyboard clock supports Gregorian years 2000 through 2099 and valid calendar fields only.")
        }
        func command(_ byte: UInt8) -> [UInt8] {
            var report = [UInt8](repeating: 0, count: reportSize)
            report[0] = 0x04; report[1] = byte
            return report
        }
        var initReport = command(0x28)
        initReport[8] = 1
        var data = [UInt8](repeating: 0, count: reportSize)
        data[1] = 1; data[2] = 0x5A
        data[3] = UInt8(year - 2000); data[4] = UInt8(month); data[5] = UInt8(day)
        data[6] = UInt8(hour); data[7] = UInt8(minute); data[8] = UInt8(second)
        data[10] = UInt8(weekday - 1)
        data[62] = 0x55; data[63] = 0xAA
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return Plan(packets: [command(0x18), initReport, data, command(0x02)],
                    timestamp: formatter.string(from: date), timezone: identifier)
    }

    static func validateResponse(_ response: [UInt8], sent: [UInt8]) throws {
        guard sent.count == reportSize, response.count == reportSize else {
            throw Failure(code: "INVALID_RESPONSE", message: "Expected a complete 64-byte feature report.")
        }
        if sent[0] == 0x04 {
            guard response[0] == sent[0], response[1] == sent[1], response[3] == 1 else {
                throw Failure(code: "MISSING_ACK", message: "The keyboard did not acknowledge the expected clock command.")
            }
        } else {
            // The upstream Mac implementation documents clock data readback as an echo.
            guard response == sent else {
                throw Failure(code: "INVALID_ECHO", message: "Clock data readback did not match the sent report.")
            }
        }
    }

    static func requireSingleDevice(_ count: Int) throws {
        guard count > 0 else { throw Failure(code: "NEEDS_WIRED", message: wiredInstructions) }
        guard count == 1 else {
            throw Failure(code: "AMBIGUOUS_DEVICE", message: "More than one exact AULA clock interface matched. Run status and select one with --device <registryID>; no device was opened or written.")
        }
    }

    // Registry IDs identify the current USB connection; re-enumerate after reconnection.
    // Explicit selection never falls back to another device if its ID is stale or absent.
    static func selectedIndex(registryIDs: [UInt64], selector: UInt64?) throws -> Int {
        if let selector {
            let matches = registryIDs.indices.filter { registryIDs[$0] == selector }
            guard matches.count == 1 else {
                throw Failure(code: "DEVICE_SELECTION_FAILED", message: "The selected registryID does not uniquely match a currently connected compatible clock interface. Run status again; no device was opened or written.")
            }
            return matches[0]
        }
        try requireSingleDevice(registryIDs.count)
        return 0
    }
}

enum AULAClockCommand {
    // Called before application construction. A recognized command emits one JSON result and exits.
    static func runIfRequested(_ arguments: [String]) {
        var finishCode: Int32 = 0
        do {
            guard let request = try AULAClockProtocol.parse(arguments) else { return }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
            // Enumeration only: do not open the manager or keyboard input interfaces.
            IOHIDManagerSetDeviceMatchingMultiple(manager, [
                [kIOHIDVendorIDKey: AULAClockProtocol.vendorID, kIOHIDProductIDKey: AULAClockProtocol.productID,
                 kIOHIDPrimaryUsagePageKey: AULAClockProtocol.usagePage, kIOHIDPrimaryUsageKey: AULAClockProtocol.usage],
                [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x024F],
            ] as CFArray)
            let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>).map(Array.init) ?? []
            let configs = devices.filter { device in
                int(device, kIOHIDVendorIDKey) == AULAClockProtocol.vendorID &&
                int(device, kIOHIDProductIDKey) == AULAClockProtocol.productID &&
                int(device, kIOHIDPrimaryUsagePageKey) == AULAClockProtocol.usagePage &&
                int(device, kIOHIDPrimaryUsageKey) == AULAClockProtocol.usage
            }
            let dongles = devices.filter {
                int($0, kIOHIDVendorIDKey) == 0x05AC && int($0, kIOHIDProductIDKey) == 0x024F &&
                (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == "F108Pro Dongle"
            }
            var result: [String: Any] = ["displayVerified": false, "matchedConfigInterfaces": configs.count,
                                       "wiredInstructions": AULAClockProtocol.wiredInstructions,
                                       "wiredInstructionsSource": "https://www.aulastar.com/faq/504.html",
                                       "observedDongleInterfaces": dongles.map(identity),
                                       "configurationInterfaces": configs.map(identity)]
            var exitCode: Int32 = 0
            result["reportsWritten"] = 0; result["reportsRead"] = 0
            result["partialWritePossible"] = false
            switch request {
            case .status:
                result["status"] = configs.isEmpty ? "NEEDS_WIRED" : (configs.count == 1 ? "WIRED_AVAILABLE" : "AMBIGUOUS_DEVICE")
                result["reportsRead"] = 0; result["reportsWritten"] = 0
            case .sync(let timezone, let selector):
                do {
                    let ids = try configs.map { device -> UInt64 in
                        guard let id = registryID(device), id > 0 else {
                            throw AULAClockProtocol.Failure(code: "DEVICE_IDENTITY_FAILED", message: "Could not read an exact configuration-interface registryID; no device was opened or written.")
                        }
                        return id
                    }
                    let index = try AULAClockProtocol.selectedIndex(registryIDs: ids, selector: selector)
                    result["selectedRegistryID"] = String(ids[index])
                    result["selection"] = selector == nil ? "automaticSingleCompatibleKeyboard" : "explicitRegistryID"
                    let plan = try AULAClockProtocol.plan(date: Date(), timezone: timezone)
                    result["timestamp"] = plan.timestamp; result["timezone"] = plan.timezone
                    var writes = 0, reads = 0
                    let receipt = try sync(device: configs[index], plan: plan) { event in
                        switch event {
                        case "writeAttempt": result["partialWritePossible"] = true
                        case "write": writes += 1; result["reportsWritten"] = writes
                        case "read": reads += 1; result["reportsRead"] = reads
                        default: break
                        }
                    }
                    result["status"] = "PROTOCOL_ACKNOWLEDGED"
                    result["partialWritePossible"] = false
                    result["reportsWritten"] = receipt.count
                    result["reportsRead"] = receipt.count
                    result["responseHex"] = receipt
                    result["meaning"] = "Transport, command acknowledgments, and clock-data echo succeeded. The displayed date and time require visual verification."
                } catch {
                    result["status"] = (error as? AULAClockProtocol.Failure)?.code ?? "HID_ERROR"
                    result["message"] = error.localizedDescription
                    exitCode = 1
                }
            }
            // Exit after this scope, so defer closes the enumeration manager first.
            emit(result)
            finishCode = exitCode
        } catch {
            emit(["status": (error as? AULAClockProtocol.Failure)?.code ?? "ERROR",
                  "message": error.localizedDescription, "displayVerified": false,
                  "wiredInstructions": AULAClockProtocol.wiredInstructions])
            finishCode = 1
        }
        exit(finishCode)
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func identity(_ device: IOHIDDevice) -> [String: Any] {
        ["product": (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "",
         "vendorID": int(device, kIOHIDVendorIDKey) ?? -1,
         "productID": int(device, kIOHIDProductIDKey) ?? -1,
         "usagePage": int(device, kIOHIDPrimaryUsagePageKey) ?? -1,
         "usage": int(device, kIOHIDPrimaryUsageKey) ?? -1,
         "locationID": int(device, kIOHIDLocationIDKey) ?? -1,
         "registryID": registryID(device).map(String.init) ?? "unavailable"]
    }

    private static func registryID(_ device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &id) == kIOReturnSuccess else { return nil }
        return id
    }

    private static func sync(device: IOHIDDevice, plan: AULAClockProtocol.Plan, progress: (String) -> Void) throws -> [String] {
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else { throw ioFailure("Opening configuration interface", opened) }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        var receipt = [String]()
        for packet in plan.packets {
            progress("writeAttempt")
            let sent = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, packet, packet.count)
            guard sent == kIOReturnSuccess else { throw ioFailure("SET_REPORT", sent) }
            progress("write")
            Thread.sleep(forTimeInterval: AULAClockProtocol.commandDelay)
            var response = [UInt8](repeating: 0, count: AULAClockProtocol.reportSize)
            var length = CFIndex(response.count)
            let read = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &response, &length)
            guard read == kIOReturnSuccess else { throw ioFailure("GET_REPORT", read) }
            progress("read")
            guard length == AULAClockProtocol.reportSize else {
                throw AULAClockProtocol.Failure(code: "INVALID_RESPONSE", message: "Keyboard returned \(length) bytes instead of 64; no further command sent.")
            }
            try AULAClockProtocol.validateResponse(response, sent: packet)
            receipt.append(response.map { String(format: "%02X", $0) }.joined())
            Thread.sleep(forTimeInterval: AULAClockProtocol.commandDelay)
        }
        return receipt
    }

    private static func ioFailure(_ operation: String, _ code: IOReturn) -> AULAClockProtocol.Failure {
        AULAClockProtocol.Failure(code: "HID_ERROR", message: String(format: "%@ failed (IOReturn 0x%08X); no further command sent.", operation, UInt32(bitPattern: code)))
    }

    private static func emit(_ result: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
