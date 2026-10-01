import AppKit
import IOKit.hid
import Observation

/// Turns USB touch screens on and off.
///
/// Two layers, because neither works on every panel:
/// 1. Seize the panel's HID interfaces so macOS stops receiving them.
/// 2. Drop pointer events whose sender is the panel's HID event service, at the HID level so the
///    cursor doesn't jump either. Every pointer event carries its sender's registry ID in CGEvent
///    field 87. This layer needs Accessibility, so turning touch off waits for that permission.
@Observable
final class TouchController {
    private(set) var deviceName: String?
    private(set) var enabled = true
    /// Touch was switched off but Dial is still waiting for Accessibility.
    private(set) var waitingForPermission = false
    var available: Bool { deviceName != nil }

    @ObservationIgnored private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    @ObservationIgnored private var seized: [IOHIDDevice] = []
    @ObservationIgnored private var senders = Set<Int64>()
    @ObservationIgnored private var tap: CFMachPort?

    init() {
        IOHIDManagerSetDeviceMatching(manager, nil)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            Unmanaged<TouchController>.fromOpaque(context!).takeUnretainedValue().devicesChanged()
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            Unmanaged<TouchController>.fromOpaque(context!).takeUnretainedValue().devicesChanged()
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        devicesChanged()
    }

    func setEnabled(_ on: Bool) {
        guard on || Access.shared.granted else {
            waitingForPermission = true
            Access.shared.ask()
            Access.shared.whenGranted { [weak self] in
                guard let self, self.waitingForPermission else { return }
                self.waitingForPermission = false
                self.setEnabled(false)
            }
            return
        }
        waitingForPermission = false
        enabled = on
        apply()
    }

    private func devicesChanged() {
        DispatchQueue.main.async {
            let screens = self.touchScreens()
            self.deviceName = screens.first.map { Self.string($0, kIOHIDProductKey) ?? "Touch screen" }
            if screens.isEmpty {
                self.release()
                self.enabled = true
                self.waitingForPermission = false
            } else if !self.enabled {
                self.apply() // re-grab after the panel re-enumerates (cable replug, monitor sleep)
            }
        }
    }

    private func apply() {
        release()
        guard !enabled else { return }
        for device in interfaces() where IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess {
            seized.append(device)
        }
        senders = senderIDs()
        startFilter()
    }

    private func release() {
        for device in seized { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) }
        seized = []
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
    }

    // MARK: Event filter

    private func startFilter() {
        guard !senders.isEmpty else { return }
        // Every event type: besides clicks and moves, panels send scrolls, gestures and system-defined events.
        let mask = CGEventMask.max
        tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                let touch = Unmanaged<TouchController>.fromOpaque(context!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = touch.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let sender = event.getIntegerValueField(CGEventField(rawValue: 87)!)
                return touch.senders.contains(sender) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Registry IDs of the HID event services belonging to the touch panel.
    private func senderIDs() -> Set<Int64> {
        let keys = Set(touchScreens().map(Self.key))
        var ids = Set<Int64>()
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDEventService"), &iterator) == KERN_SUCCESS else { return ids }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let vendor = IORegistryEntryCreateCFProperty(service, kIOHIDVendorIDKey as CFString, nil, 0)?.takeRetainedValue() as? Int ?? -1
            let product = IORegistryEntryCreateCFProperty(service, kIOHIDProductIDKey as CFString, nil, 0)?.takeRetainedValue() as? Int ?? -1
            guard keys.contains("\(vendor):\(product)") else { continue }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            ids.insert(Int64(bitPattern: id))
        }
        return ids
    }

    // MARK: HID devices

    private var allDevices: [IOHIDDevice] {
        Array((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [])
    }

    /// Devices whose primary usage is Digitizer / Touch Screen.
    private func touchScreens() -> [IOHIDDevice] {
        allDevices.filter {
            Self.int($0, kIOHIDPrimaryUsagePageKey) == kHIDPage_Digitizer && Self.int($0, kIOHIDPrimaryUsageKey) == kHIDUsage_Dig_TouchScreen
        }
    }

    /// Every interface of the touch screen, including the mouse-emulation one many panels expose.
    private func interfaces() -> [IOHIDDevice] {
        let ids = Set(touchScreens().map(Self.key))
        return allDevices.filter { ids.contains(Self.key($0)) }
    }

    private static func key(_ device: IOHIDDevice) -> String {
        "\(int(device, kIOHIDVendorIDKey)):\(int(device, kIOHIDProductIDKey))"
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? -1
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
