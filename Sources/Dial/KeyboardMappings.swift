import Foundation
import CoreGraphics
import Observation

struct DialKeyChord: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt64

    static let modifierMask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue

    init(keyCode: UInt16, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    var label: String {
        let flags = CGEventFlags(rawValue: modifiers)
        return (flags.contains(.maskControl) ? "⌃" : "") +
            (flags.contains(.maskAlternate) ? "⌥" : "") +
            (flags.contains(.maskShift) ? "⇧" : "") +
            (flags.contains(.maskCommand) ? "⌘" : "") + Self.name(for: keyCode)
    }

    static func name(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V", 11:"B",
            12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2", 20:"3", 21:"4",
            22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"−", 28:"8", 29:"0", 30:"]", 31:"O",
            32:"U", 33:"[", 34:"I", 35:"P", 36:"Return", 37:"L", 38:"J", 39:"'", 40:"K",
            41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 48:"Tab", 49:"Space",
            50:"`", 51:"Delete", 53:"Escape", 54:"Right Command", 55:"Command", 56:"Shift",
            57:"Caps Lock", 58:"Option", 59:"Control", 60:"Right Shift", 61:"Right Option",
            62:"Right Control", 63:"Fn", 64:"F17", 65:"Keypad .", 67:"Keypad *", 69:"Keypad +",
            71:"Num Lock / Keypad Clear", 75:"Keypad /", 76:"Keypad Enter", 78:"Keypad −", 79:"F18",
            80:"F19", 81:"Keypad =", 82:"Keypad 0", 83:"Keypad 1", 84:"Keypad 2", 85:"Keypad 3",
            86:"Keypad 4", 87:"Keypad 5", 88:"Keypad 6", 89:"Keypad 7", 91:"Keypad 8", 92:"Keypad 9",
            96:"F5", 97:"F6", 98:"F7", 99:"F3", 100:"F8", 101:"F9", 103:"F11",
            105:"Print Screen / F13", 106:"F16", 107:"Scroll Lock / F14", 109:"F10", 111:"F12", 113:"F15",
            114:"Help", 115:"Home", 116:"Page Up", 117:"Forward Delete", 118:"F4", 119:"End",
            120:"F2", 121:"Page Down", 122:"F1", 123:"←", 124:"→", 125:"↓", 126:"↑"
        ]
        return names[code] ?? "Key \(code)"
    }

    var isModifierOnly: Bool { (54...63).contains(keyCode) }
    static let keypadCodes: Set<UInt16> = [65, 67, 69, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    var isKeypadKey: Bool { Self.keypadCodes.contains(keyCode) }
}

enum KeyboardNativeAction: String, Codable, CaseIterable {
    case screenshotSelection = "screenshot-selection"
    case copyScreenshotSelection = "copy-screenshot-selection"
    case scrollingScreenshot = "scrolling-screenshot"
    case copyScrollingScreenshot = "copy-scrolling-screenshot"

    var displayName: String {
        switch self {
        case .screenshotSelection: return "Screenshot selection"
        case .copyScreenshotSelection: return "Copy screenshot selection"
        case .scrollingScreenshot: return "Scrolling screenshot"
        case .copyScrollingScreenshot: return "Copy scrolling screenshot"
        }
    }
}

struct KeyMapping: Identifiable, Codable {
    var id: UUID = UUID()
    var input: DialKeyChord
    var output: DialKeyChord
    var enabled: Bool = true
    var nativeAction: KeyboardNativeAction? = nil
}

@Observable
final class KeyboardMappings {
    static let shared = KeyboardMappings()
    private(set) var mappings: [KeyMapping]
    var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey) } }
    var numLockOn: Bool { didSet { defaults.set(numLockOn, forKey: Self.numLockKey) } }
    var numpadMode: String {
        didSet {
            if numpadMode != "navigation" && numpadMode != "disabled" { numpadMode = "disabled" }
            defaults.set(numpadMode, forKey: Self.numpadModeKey)
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    private static let mappingsKey = "keyboardMappings.v1"
    private static let enabledKey = "keyboardMappings.enabled"
    private static let numLockKey = "keyboardMappings.numLockOn"
    private static let numpadModeKey = "keyboardMappings.numpadMode"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        numLockOn = defaults.object(forKey: Self.numLockKey) as? Bool ?? true
        let mode = defaults.string(forKey: Self.numpadModeKey)
        numpadMode = mode == "navigation" ? "navigation" : "disabled"
        mappings = Self.readMappings(from: defaults)
    }

    /// Refresh a live GUI model after another process changes the persisted configuration.
    func reload() {
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        numLockOn = defaults.object(forKey: Self.numLockKey) as? Bool ?? true
        numpadMode = defaults.string(forKey: Self.numpadModeKey) == "navigation" ? "navigation" : "disabled"
        mappings = Self.readMappings(from: defaults)
    }

    private static func readMappings(from defaults: UserDefaults) -> [KeyMapping] {
        if let data = defaults.data(forKey: Self.mappingsKey),
           let saved = try? JSONDecoder().decode([KeyMapping].self, from: data) {
            return saved.filter { !$0.input.isModifierOnly && !$0.output.isModifierOnly }.map {
                var mapping = $0
                mapping.input = DialKeyChord(keyCode: $0.input.keyCode, modifiers: $0.input.modifiers)
                mapping.output = $0.nativeAction == nil ? DialKeyChord(keyCode: $0.output.keyCode, modifiers: $0.output.modifiers) : mapping.input
                return mapping
            }
        } else {
            return [
                KeyMapping(input: DialKeyChord(keyCode: 105, modifiers: 0),
                           output: DialKeyChord(keyCode: 105, modifiers: 0),
                           nativeAction: .screenshotSelection),
                KeyMapping(input: DialKeyChord(keyCode: 105, modifiers: CGEventFlags.maskControl.rawValue),
                           output: DialKeyChord(keyCode: 105, modifiers: CGEventFlags.maskControl.rawValue),
                           nativeAction: .copyScreenshotSelection)
            ]
        }
    }

    func assign(input: DialKeyChord, output: DialKeyChord) {
        guard !input.isModifierOnly, !output.isModifierOnly else { return }
        if let index = mappings.firstIndex(where: { $0.input == input }) {
            mappings[index].output = output
            mappings[index].nativeAction = nil
            mappings[index].enabled = true
        } else {
            mappings.append(KeyMapping(input: input, output: output))
        }
        save()
    }

    func assign(input: DialKeyChord, action: KeyboardNativeAction) {
        guard !input.isModifierOnly else { return }
        if let index = mappings.firstIndex(where: { $0.input == input }) {
            mappings[index].output = input
            mappings[index].nativeAction = action
            mappings[index].enabled = true
        } else {
            mappings.append(KeyMapping(input: input, output: input, nativeAction: action))
        }
        save()
    }

    func remove(id: UUID) {
        mappings.removeAll { $0.id == id }
        save()
    }

    func setEnabled(id: UUID, on: Bool) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        mappings[index].enabled = on
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mappings) { defaults.set(data, forKey: Self.mappingsKey) }
    }
}

/// Holds destination chords until the matching release, even if configuration or modifiers change.
struct KeyboardMappingPolicy {
    enum Decision: Equatable { case pass, consume, transform(DialKeyChord), perform(KeyboardNativeAction) }
    private enum Held { case transform(DialKeyChord), native }
    private var held: [UInt16: Held] = [:]

    func isHolding(_ keyCode: UInt16) -> Bool { held[keyCode] != nil }

    mutating func reset() { held.removeAll() }

    /// Return one paired release destination for every transformed press, then forget them.
    mutating func drain() -> [DialKeyChord] {
        let destinations = held.keys.sorted().compactMap { code -> DialKeyChord? in
            if case .transform(let output) = held[code] { return output }
            return nil
        }
        held.removeAll()
        return destinations
    }

    mutating func route(_ chord: DialKeyChord, down: Bool, repeating: Bool,
                        enabled: Bool, mappings: [KeyMapping], paused: Bool) -> Decision {
        if let prior = held[chord.keyCode] {
            if !down { held.removeValue(forKey: chord.keyCode) }
            switch prior {
            case .native: return .consume
            case .transform(let destination): return down ? .consume : .transform(destination)
            }
        }
        guard down, !repeating, !paused, enabled, !chord.isModifierOnly,
              let mapping = mappings.first(where: { $0.enabled && $0.input == chord }) else { return .pass }
        if let action = mapping.nativeAction {
            held[chord.keyCode] = .native
            return .perform(action)
        }
        held[chord.keyCode] = .transform(mapping.output)
        return .transform(mapping.output)
    }
}
