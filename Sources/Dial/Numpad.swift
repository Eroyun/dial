import Foundation

/// Software Num Lock for keyboards that macOS reports as Keypad Clear.
/// Each physical press retains its original route until release, including numeric passes.
struct NumpadPolicy {
    enum Decision: Equatable { case pass, consume, toggle, transform(DialKeyChord), perform(KeyboardNativeAction) }
    private enum Held { case pass, consume, transform(DialKeyChord) }
    private var held: [UInt16: Held] = [:]
    static let keypadCodes = DialKeyChord.keypadCodes
    private static let navigation: [UInt16: UInt16] = [
        65:117, 82:114, 83:119, 84:125, 85:121, 86:123,
        88:124, 89:115, 91:126, 92:116
    ]

    func isHolding(_ keyCode: UInt16) -> Bool { held[keyCode] != nil }

    mutating func route(_ chord: DialKeyChord, down: Bool, repeating: Bool,
                        numLockOn: Bool, mode: String, paused: Bool) -> Decision {
        // Complete a route already delivered before recording or configuration changes.
        if let prior = held[chord.keyCode] {
            if !down { held.removeValue(forKey: chord.keyCode) }
            switch prior {
            case .pass: return .pass
            case .consume: return .consume
            case .transform(let output): return .transform(output)
            }
        }
        guard !paused else { return .pass }
        if chord.keyCode == 71 {
            guard down else { return .consume }
            held[chord.keyCode] = .consume
            return repeating ? .consume : .toggle
        }
        guard Self.keypadCodes.contains(chord.keyCode) else { return .pass }
        // Starting while a key is already held must not leak digits through a disabled pad.
        if !numLockOn && mode == "disabled" {
            if down { held[chord.keyCode] = .consume }
            return .consume
        }
        guard down, !repeating else { return .pass }
        let result: Decision
        if numLockOn {
            held[chord.keyCode] = .pass
            result = .pass
        } else if mode == "disabled" || chord.keyCode == 87 {
            held[chord.keyCode] = .consume
            result = .consume
        } else if let code = Self.navigation[chord.keyCode] {
            let output = DialKeyChord(keyCode: code, modifiers: chord.modifiers)
            held[chord.keyCode] = .transform(output)
            result = .transform(output)
        } else {
            // Operators and Enter retain their ordinary behavior in navigation mode.
            held[chord.keyCode] = .pass
            result = .pass
        }
        return result
    }

    mutating func drain() -> [DialKeyChord] {
        let outputs = held.keys.sorted().compactMap { code -> DialKeyChord? in
            if case .transform(let output) = held[code] { return output }
            return nil
        }
        held.removeAll()
        return outputs
    }
}

/// The same dispatcher used by the event tap: a disabled pad preempts new custom
/// actions, while routes already delivered always finish their paired releases.
struct KeyboardRoutingPolicy {
    typealias Decision = NumpadPolicy.Decision
    private var mappingsPolicy = KeyboardMappingPolicy()
    private var numpadPolicy = NumpadPolicy()

    func isHolding(_ keyCode: UInt16) -> Bool {
        mappingsPolicy.isHolding(keyCode) || numpadPolicy.isHolding(keyCode)
    }

    mutating func route(_ chord: DialKeyChord, down: Bool, repeating: Bool,
                        mappingsEnabled: Bool, mappings: [KeyMapping],
                        numLockOn: Bool, mode: String, paused: Bool) -> Decision {
        if mappingsPolicy.isHolding(chord.keyCode) {
            return convert(mappingsPolicy.route(chord, down: down, repeating: repeating,
                enabled: mappingsEnabled, mappings: mappings, paused: paused))
        }
        if numpadPolicy.isHolding(chord.keyCode) {
            return numpadPolicy.route(chord, down: down, repeating: repeating,
                numLockOn: numLockOn, mode: mode, paused: paused)
        }
        guard !paused else { return .pass }
        if !numLockOn && mode == "disabled" && NumpadPolicy.keypadCodes.contains(chord.keyCode) {
            return numpadPolicy.route(chord, down: down, repeating: repeating,
                numLockOn: numLockOn, mode: mode, paused: false)
        }
        let mapped = mappingsPolicy.route(chord, down: down, repeating: repeating,
            enabled: mappingsEnabled, mappings: mappings, paused: false)
        switch mapped {
        case .consume, .transform, .perform: return convert(mapped)
        case .pass:
            // Num Lock / Clear (71) remains available for an intentional custom mapping.
            return numpadPolicy.route(chord, down: down, repeating: repeating,
                numLockOn: numLockOn, mode: mode, paused: false)
        }
    }

    mutating func drain() -> [DialKeyChord] { mappingsPolicy.drain() + numpadPolicy.drain() }

    private func convert(_ decision: KeyboardMappingPolicy.Decision) -> Decision {
        switch decision {
        case .pass: return .pass
        case .consume: return .consume
        case .transform(let chord): return .transform(chord)
        case .perform(let action): return .perform(action)
        }
    }
}
