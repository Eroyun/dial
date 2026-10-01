import AppKit
import CoreAudio
import Observation

/// Routes the keyboard's brightness and volume keys to external displays.
/// Brightness follows the display under the pointer; volume follows the
/// current sound output when that output is a monitor's HDMI/DisplayPort audio.
@Observable
final class KeyRouter {
    private(set) var active = false
    var wanted: Bool {
        didSet {
            UserDefaults.standard.set(wanted, forKey: "keys")
            wanted ? start() : stop()
        }
    }

    @ObservationIgnored private let store: DisplayStore
    @ObservationIgnored private var tap: CFMachPort?
    private let step = 1.0 / 16

    init(store: DisplayStore) {
        self.store = store
        self.wanted = UserDefaults.standard.object(forKey: "keys") as? Bool ?? true
        if wanted { start() }
    }

    private func start() {
        guard tap == nil else { return }
        guard Access.shared.granted else {
            Access.shared.whenGranted { [weak self] in if self?.wanted == true { self?.start() } }
            return
        }
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) // 14 = NX_SYSDEFINED
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                let router = Unmanaged<KeyRouter>.fromOpaque(context!).takeUnretainedValue()
                return router.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        active = true
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        active = false
    }

    private enum Key { case brightnessUp, brightnessDown, volumeUp, volumeDown, mute }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let (key, down) = key(for: type, event) else { return Unmanaged.passUnretained(event) }
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        let delta = fine ? step / 4 : step

        switch key {
        case .brightnessUp, .brightnessDown:
            guard let display = store.display(at: event.location), let value = display.brightness else { break }
            guard down else { return nil } // swallow the key-up too, or macOS shows its own HUD
            let next = (value + (key == .brightnessUp ? delta : -delta)).clamped
            display.setBrightness(next)
            HUD.show(symbol: "sun.max.fill", value: next, on: display.id)
            return nil
        case .volumeUp, .volumeDown, .mute:
            guard let display = audioDisplay(), let value = display.volume else { break }
            guard down else { return nil }
            let next = key == .mute ? 0 : (value + (key == .volumeUp ? delta : -delta)).clamped
            display.setVolume(next)
            HUD.show(symbol: next == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", value: next, on: display.id)
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func key(for type: CGEventType, _ event: CGEvent) -> (Key, down: Bool)? {
        if type == .keyDown {
            // Apple keyboards on recent macOS send brightness as plain key codes.
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: return (.brightnessUp, true)
            case 145: return (.brightnessDown, true)
            default: return nil
            }
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return nil }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let down = ((ns.data1 & 0xFF00) >> 8) == 0xA
        switch code {
        case 0: return (.volumeUp, down)
        case 1: return (.volumeDown, down)
        case 2: return (.brightnessUp, down)
        case 3: return (.brightnessDown, down)
        case 7: return (.mute, down)
        default: return nil
        }
    }

    /// The display whose speakers are the current sound output, if any.
    private func audioDisplay() -> ExternalDisplay? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }

        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return store.display(named: name.takeRetainedValue() as String)
    }
}
