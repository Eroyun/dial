import IOKit.hid
import Observation

/// Turns USB touch screens on and off by seizing their HID interfaces,
/// so macOS stops receiving their events. Releasing them restores touch.
@Observable
final class TouchController {
    private(set) var deviceName: String?
    private(set) var enabled = true
    private(set) var error: String?
    var available: Bool { deviceName != nil }

    @ObservationIgnored private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    @ObservationIgnored private var seized: [IOHIDDevice] = []

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
        enabled = on
        apply()
    }

    private func devicesChanged() {
        DispatchQueue.main.async {
            self.deviceName = self.touchScreens().first.map { Self.string($0, kIOHIDProductKey) ?? "Touch screen" }
            if self.deviceName == nil { self.seized = []; self.enabled = true; self.error = nil }
            else if !self.enabled { self.apply() }
        }
    }

    private func apply() {
        release()
        guard !enabled else { error = nil; return }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        for device in interfaces() {
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess {
                seized.append(device)
            }
        }
        if seized.isEmpty {
            enabled = true
            error = "Allow Dial in Privacy & Security → Input Monitoring"
        } else {
            error = nil
        }
    }

    private func release() {
        for device in seized { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) }
        seized = []
    }

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
