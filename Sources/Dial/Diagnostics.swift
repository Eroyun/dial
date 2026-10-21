import AppKit
import IOKit

/// Passive inventory: no mode restoration, DDC transactions, gamma changes, or HID seizure.
enum DisplayDiagnostics {
    static func run() -> Never {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let status = CGGetOnlineDisplayList(16, &ids, &count)
        var displays: [[String: Any]] = []
        if status == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) == 0 {
                var item: [String: Any] = [
                    "id": id,
                    "name": name(of: id),
                    "vendor": CGDisplayVendorNumber(id),
                    "model": CGDisplayModelNumber(id),
                    "serial": CGDisplaySerialNumber(id),
                    "online": CGDisplayIsOnline(id) != 0,
                ]
                if let mode = CGDisplayCopyDisplayMode(id) {
                    item["logicalSize"] = "\(mode.width)x\(mode.height)"
                    // These are rendering pixels, not necessarily the signal sent over the cable.
                    item["renderingSize"] = "\(mode.pixelWidth)x\(mode.pixelHeight)"
                    item["refreshHz"] = mode.refreshRate
                    item["modeID"] = mode.ioDisplayModeID
                    item["ioFlags"] = mode.ioFlags
                    item["modeFingerprint"] = DisplayMode(mode).fingerprint
                }
                let key = "mode-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
                item["rememberedMode"] = UserDefaults.standard.string(forKey: key) ?? "none"
                item["rememberedModeFingerprint"] = UserDefaults.standard.string(forKey: key + "-fingerprint") ?? "none"
                displays.append(item)
            }
        }
        let report: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "displayEnumerationStatus": status.rawValue,
            "displays": displays,
            "usbProducts": usbProducts(),
            "note": "USB devices are listed separately; a touchscreen USB connection does not establish a video connection. Rendering size is not physical signal resolution.",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data)
            print()
        } catch {
            fputs("Could not encode display diagnostics: \(error)\n", stderr)
            exit(1)
        }
        exit(status == .success ? 0 : 1)
    }

    /// Save an already-confirmed mode without reconfiguring a display or starting the GUI.
    static func saveCurrent(_ args: [String]) -> Never {
        guard args.count == 2, let expectedHz = Int(args[1]) else {
            print("usage: Dial --save-current <display name> <expected refresh Hz>")
            exit(2)
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { exit(1) }
        let matches = ids.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && name(of: $0).caseInsensitiveCompare(args[0]) == .orderedSame
        }
        guard matches.count == 1, let id = matches.first else {
            print("Expected one connected display named \(args[0]); found \(matches.count).")
            exit(1)
        }
        let display = ExternalDisplay(id: id, name: name(of: id), ddc: nil)
        guard display.saveCurrentMode(expectedRefresh: expectedHz), let mode = display.current else {
            print("The display is not running at the expected \(expectedHz) Hz; nothing saved.")
            exit(1)
        }
        print("Remembered \(mode.sizeKey)@\(mode.hz) for \(display.name); video settings were not changed.")
        exit(0)
    }

    private static func name(of id: CGDirectDisplayID) -> String {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName ?? "Display \(id)"
    }

    private static func usbProducts() -> [String] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var products = Set<String>()
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let product = IORegistryEntryCreateCFProperty(entry, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                products.insert(product)
            }
        }
        return products.sorted()
    }
}
