import Foundation
import CoreGraphics

@main
struct NumpadPolicyTests {
    static func main() {
        var policy = NumpadPolicy()
        func chord(_ code: UInt16, _ modifiers: UInt64 = 0) -> DialKeyChord { DialKeyChord(keyCode: code, modifiers: modifiers) }
        func route(_ code: UInt16, down: Bool = true, repeatKey: Bool = false,
                   on: Bool = false, mode: String = "disabled", paused: Bool = false) -> NumpadPolicy.Decision {
            policy.route(chord(code), down: down, repeating: repeatKey, numLockOn: on, mode: mode, paused: paused)
        }
        precondition(route(71) == .toggle, "Num Lock toggles on first down")
        precondition(route(71, repeatKey: true) == .consume, "Held Num Lock never repeats toggle")
        precondition(route(71, down: false) == .consume, "Toggle release consumed")
        precondition(route(71, repeatKey: true) == .consume, "Orphan toggle repeat does not toggle")
        precondition(route(71, down: false) == .consume, "Orphan repeat release consumed")
        precondition(route(71, paused: true) == .pass, "Recorder can capture Num Lock")
        precondition(route(82, repeatKey: true) == .consume, "Orphan numeric repeat swallowed when disabled")
        precondition(route(82, down: false) == .consume, "Orphan repeat release swallowed")
        precondition(route(83, down: false) == .consume, "Unmatched release swallowed when disabled")
        for code in NumpadPolicy.keypadCodes.sorted() {
            precondition(route(code) == .consume, "Disabled keypad down swallowed: \(code)")
            precondition(route(code, repeatKey: true, on: true, mode: "navigation") == .consume, "Disabled press stays disabled across state changes")
            precondition(route(code, down: false, on: true) == .consume, "Disabled keypad paired release swallowed")
            precondition(route(code, on: true) == .pass, "Enabled keypad remains numeric")
            precondition(route(code, repeatKey: true) == .pass, "Numeric repeat remains numeric after disabling")
            precondition(route(code, down: false) == .pass, "Numeric release remains unchanged after disabling")
        }
        let navigation: [UInt16:UInt16] = [65:117,82:114,83:119,84:125,85:121,86:123,88:124,89:115,91:126,92:116]
        for (input, output) in navigation {
            precondition(route(input, mode: "navigation") == .transform(chord(output)), "Navigation destination")
            precondition(route(input, repeatKey: true, on: true) == .transform(chord(output)), "Navigation repeat retains destination across toggle")
            precondition(route(input, down: false, on: true) == .transform(chord(output)), "Navigation release retains destination")
        }
        precondition(route(87, mode: "navigation") == .consume, "Navigation center 5 consumed")
        precondition(route(87, down: false, on: true) == .consume, "Center release consumed")
        precondition(route(76, mode: "navigation") == .pass, "Navigation Enter preserved")
        precondition(route(76, down: false) == .pass, "Preserved Enter release")
        precondition(route(0) == .pass, "Ordinary keyboard remains usable")
        precondition(route(83, paused: true) == .pass, "Recording pauses keypad handling")
        precondition(route(83, down: false, paused: true) == .pass, "Recording paired release passes policy")
        let shifted = chord(84, CGEventFlags.maskShift.rawValue)
        precondition(policy.route(shifted, down: true, repeating: false, numLockOn: false, mode: "navigation", paused: false) == .transform(chord(125, shifted.modifiers)), "Navigation preserves modifiers")
        precondition(route(82, on: true) == .pass, "Normal held number for drain")
        precondition(route(87) == .consume, "Disabled held key for drain")
        precondition(policy.drain() == [chord(125, shifted.modifiers)], "Recovery releases only transformed destinations")
        precondition(policy.drain().isEmpty, "Recovery releases occur once")
        precondition(route(84, down: false, on: true) == .pass, "Interrupted release no longer transformed")

        var dispatcher = KeyboardRoutingPolicy()
        let customCopy = DialKeyChord(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue)
        let copyMapping = KeyMapping(input: chord(83), output: customCopy)
        func dispatch(_ code: UInt16, down: Bool = true, repeatKey: Bool = false,
                      on: Bool = false, paused: Bool = false, mappings: [KeyMapping]? = nil) -> KeyboardRoutingPolicy.Decision {
            dispatcher.route(chord(code), down: down, repeating: repeatKey,
                mappingsEnabled: true, mappings: mappings ?? [copyMapping],
                numLockOn: on, mode: "disabled", paused: paused)
        }
        precondition(dispatch(83) == .consume, "Disabled keypad 1 preempts assigned Cmd-C action in live dispatcher")
        precondition(dispatch(83, repeatKey: true, on: true) == .consume, "Disabled mapped press remains consumed after enabling")
        precondition(dispatch(83, down: false, on: true) == .consume, "Disabled mapped paired release remains consumed")
        precondition(dispatch(83, on: true) == .transform(customCopy), "Enabled keypad permits custom actions")
        precondition(dispatch(83, repeatKey: true) == .consume, "Existing mapped repeat stays consumed after disabling")
        precondition(dispatch(83, down: false) == .transform(customCopy), "Existing mapped destination receives paired release after disabling")
        precondition(dispatch(83, paused: true) == .pass, "Recorder can capture disabled keypad with a custom assignment")
        precondition(dispatch(71) == .toggle, "Unassigned Num Lock toggles while keypad disabled")
        precondition(dispatch(71, down: false) == .consume, "Num Lock release consumed by live dispatcher")
        let lockMapping = KeyMapping(input: chord(71), output: customCopy)
        precondition(dispatch(71, mappings: [lockMapping]) == .transform(customCopy), "Intentional Num Lock assignment overrides default toggle")
        precondition(dispatcher.drain() == [customCopy], "Recovery drains existing custom output exactly once")
        precondition(dispatcher.drain().isEmpty, "Live dispatcher drain does not duplicate releases")

        let suite = "Dial.NumpadTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = KeyboardMappings(defaults: defaults)
        precondition(settings.numLockOn && settings.numpadMode == "disabled", "Safe initial Num Lock state and requested disabled mode")
        settings.numLockOn = false
        settings.numpadMode = "navigation"
        let other = KeyboardMappings(defaults: defaults)
        precondition(!other.numLockOn && other.numpadMode == "navigation", "Num Lock settings persist")
        other.enabled = false
        other.numLockOn = true
        other.numpadMode = "disabled"
        other.remove(id: other.mappings[0].id)
        settings.reload()
        precondition(!settings.enabled && settings.numLockOn && settings.numpadMode == "disabled" && settings.mappings.count == 1, "Reload updates all persisted fields and mappings")
        settings.numpadMode = "invalid"
        precondition(settings.numpadMode == "disabled" && defaults.string(forKey: "keyboardMappings.numpadMode") == "disabled", "Invalid mode normalizes to requested disabled mode")
        print("Numpad policy and persistence checks passed")
    }
}
