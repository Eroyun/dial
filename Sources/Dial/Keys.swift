import AppKit
import CoreAudio
import Observation

/// Routes the keyboard's brightness and volume keys to external displays.
/// Brightness follows the display under the pointer; volume follows the
/// current sound output when that output is a monitor's HDMI/DisplayPort audio.
@Observable
final class KeyRouter {
    private(set) var active = false
    private(set) var capturedChord: DialKeyChord?
    private(set) var recording = false
    @ObservationIgnored var onNativeAction: ((KeyboardNativeAction) -> Void)?
    @ObservationIgnored var cancelCaptureSelectionForKey: (() -> Bool)?
    @ObservationIgnored weak var recordingWindow: NSWindow?
    @ObservationIgnored private var capturedHeld: Set<UInt16> = []
    @ObservationIgnored private var capturedAuxiliaryHeld: Set<Int> = []
    @ObservationIgnored private var keyboardPolicy = KeyboardRoutingPolicy()
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var cleanedUp = false

    @ObservationIgnored private let store: DisplayStore?
    @ObservationIgnored private let mappings: KeyboardMappings
    @ObservationIgnored private let postRelease: (DialKeyChord) -> Void
    @ObservationIgnored private var tap: CFMachPort?
    private let step = 1.0 / 16
    private static let releaseEventTag: Int64 = 0x4449414C4B455955

    init(store: DisplayStore?, startMonitoring: Bool = true,
         mappings: KeyboardMappings? = nil, postRelease: ((DialKeyChord) -> Void)? = nil) {
        self.store = store
        self.mappings = mappings ?? .shared
        self.postRelease = postRelease ?? Self.postRelease
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.cleanUp() }
        if startMonitoring { start() }
    }

    func beginRecording() {
        capturedChord = nil
        recording = true
    }

    func cancelRecording() { recording = false }
    func clearCapturedChord() { capturedChord = nil }

    deinit { cleanUp() }

    private func cleanUp() {
        guard !cleanedUp else { return }
        cleanedUp = true
        releaseHeldOutputs()
        capturedHeld.removeAll()
        capturedAuxiliaryHeld.removeAll()
        recording = false
        active = false
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
    }

    /// Release mapped keys if Dial exits or its event tap is disabled during a key press.
    private func releaseHeldOutputs() {
        for chord in keyboardPolicy.drain() {
            postRelease(chord)
        }
    }

    private static func postRelease(_ chord: DialKeyChord) {
        guard let release = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: false) else { return }
        release.flags = CGEventFlags(rawValue: chord.modifiers)
        release.setIntegerValueField(.eventSourceUserData, value: releaseEventTag)
        release.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func start() {
        guard !cleanedUp, tap == nil else { return }
        guard Access.shared.granted else {
            Access.shared.whenGranted { [weak self] in self?.start() }
            return
        }
        let mask = CGEventMask(1 << 14) | CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue) // 14 = NX_SYSDEFINED
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
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        active = true
    }

    private enum Key { case brightnessUp, brightnessDown, volumeUp, volumeDown, mute }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard !cleanedUp else { return Unmanaged.passUnretained(event) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            releaseHeldOutputs()
            capturedHeld.removeAll()
            capturedAuxiliaryHeld.removeAll()
            recording = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.releaseEventTag {
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            let chord = DialKeyChord(keyCode: code, modifiers: event.flags.rawValue)
            let down = type == .keyDown
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if capturedHeld.contains(code) {
                if !down { capturedHeld.remove(code) }
                return nil
            }
            // Selection owns every key before mappings or display hotkeys can
            // turn it into another action. Consume its matching release too.
            if down, !autorepeat, !keyboardPolicy.isHolding(code), cancelCaptureSelectionForKey?() == true {
                capturedHeld.insert(code)
                return nil
            }
            let canRecord = recording && NSApp.isActive && recordingWindow?.isKeyWindow == true
            if recording && !canRecord { recording = false }
            let decision = keyboardPolicy.route(chord, down: down,
                repeating: autorepeat,
                mappingsEnabled: mappings.enabled, mappings: mappings.mappings,
                numLockOn: mappings.numLockOn, mode: mappings.numpadMode, paused: canRecord)
            switch decision {
            case .perform(let action):
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.cleanedUp else { return }
                    self.onNativeAction?(action)
                }
                return nil
            case .consume: return nil
            case .toggle:
                mappings.numLockOn.toggle()
                return nil
            case .transform(let destination):
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(destination.keyCode))
                event.flags = CGEventFlags(rawValue: destination.modifiers)
                event.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
                return Unmanaged.passUnretained(event)
            case .pass: break
            }
            if canRecord, down, !chord.isModifierOnly,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                capturedChord = chord
                capturedHeld.insert(code)
                recording = false
                return nil
            }

        }
        // NX_SYSDEFINED also carries mouse/device notifications. Only subtype
        // 8 is an auxiliary keyboard event; a left click must reach the picker.
        if type.rawValue == 14, let systemEvent = NSEvent(cgEvent: event),
           systemEvent.subtype.rawValue == 8 {
            let code = (systemEvent.data1 & 0xFFFF0000) >> 16
            let down = ((systemEvent.data1 & 0xFF00) >> 8) == 0xA
            if capturedAuxiliaryHeld.contains(code) {
                if !down { capturedAuxiliaryHeld.remove(code) }
                return nil
            }
            if down, cancelCaptureSelectionForKey?() == true {
                capturedAuxiliaryHeld.insert(code)
                return nil
            }
        }
        guard let (key, down) = key(for: type, event) else { return Unmanaged.passUnretained(event) }
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        let delta = fine ? step / 4 : step

        switch key {
        case .brightnessUp, .brightnessDown:
            guard let display = store?.display(at: event.location), let value = display.brightness else { break }
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
        if type == .keyDown || type == .keyUp {
            // Apple keyboards on recent macOS send brightness as plain key codes.
            switch event.getIntegerValueField(.keyboardEventKeycode) {
            case 144: return (.brightnessUp, type == .keyDown)
            case 145: return (.brightnessDown, type == .keyDown)
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
        return store?.display(named: name.takeRetainedValue() as String)
    }
}
