import Foundation
import CoreGraphics

@main
struct KeyboardMappingsTests {
    static func main() {
        let suite = "Dial.KeyboardMappingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeyboardMappings(defaults: defaults)
        let input = DialKeyChord(keyCode: 105, modifiers: 0)
        let ctrlInput = DialKeyChord(keyCode: 105, modifiers: CGEventFlags.maskControl.rawValue)
        // Exercise literal shortcut pairing independently of the native action defaults.
        store.assign(input: input, output: DialKeyChord(keyCode: 21, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue))
        store.assign(input: ctrlInput, output: DialKeyChord(keyCode: 21, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue))
        let output = store.mappings[0].output
        let ctrlOutput = store.mappings[1].output
        var policy = KeyboardMappingPolicy()
        func check(_ result: KeyboardMappingPolicy.Decision, _ expected: KeyboardMappingPolicy.Decision, _ message: String) {
            precondition(result == expected, message)
        }
        check(policy.route(input, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(output), "Print Screen routes to the native screenshot chord")
        check(policy.route(ctrlInput, down: true, repeating: true, enabled: true, mappings: store.mappings, paused: false), .consume, "Repeat consumed despite changed modifiers")
        check(policy.route(ctrlInput, down: false, repeating: false, enabled: false, mappings: [], paused: true), .transform(output), "Mapped release stays paired after configuration and modifier changes")
        check(policy.route(ctrlInput, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(ctrlOutput), "Control Print routes to the native copy-screenshot chord")
        check(policy.route(input, down: false, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(ctrlOutput), "Copy chord release stays paired")
        let extra = DialKeyChord(keyCode: 105, modifiers: CGEventFlags.maskAlternate.rawValue)
        check(policy.route(extra, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: false), .pass, "Unrelated combination passes")
        check(policy.route(input, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: true), .pass, "Recording pauses mappings")
        check(policy.route(input, down: true, repeating: false, enabled: false, mappings: store.mappings, paused: false), .pass, "Global disable")
        check(policy.route(input, down: true, repeating: true, enabled: true, mappings: store.mappings, paused: false), .pass, "Orphan repeat passes")
        check(policy.route(input, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(output), "Pre-interruption mapping")
        policy.reset()
        check(policy.route(input, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(output), "Fresh press works after interrupted tap missed release")
        check(policy.route(input, down: false, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(output), "Fresh release after interruption")
        check(policy.route(input, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(output), "Held destination before drain")
        let secondInput = DialKeyChord(keyCode: 107, modifiers: 0)
        let secondMapping = KeyMapping(input: secondInput, output: ctrlOutput)
        check(policy.route(secondInput, down: true, repeating: false, enabled: true, mappings: [secondMapping], paused: false), .transform(ctrlOutput), "Second held destination before drain")
        precondition(policy.drain() == [output, ctrlOutput], "Drain releases both transformed screenshot chords")
        precondition(policy.drain().isEmpty, "Drain empties held state exactly once")
        check(policy.route(input, down: false, repeating: false, enabled: true, mappings: store.mappings, paused: false), .pass, "Drained release is no longer transformed")
        check(policy.route(input, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(output), "Fresh press works after drain")
        check(policy.route(input, down: false, repeating: false, enabled: true, mappings: store.mappings, paused: false), .transform(output), "Fresh paired release after drain")
        let customPrint = KeyMapping(input: input, output: DialKeyChord(keyCode: 12, modifiers: CGEventFlags.maskCommand.rawValue))
        check(policy.route(input, down: true, repeating: false, enabled: true, mappings: [customPrint], paused: false), .transform(customPrint.output), "Custom Print mappings keep their chord behavior")
        check(policy.route(ctrlInput, down: false, repeating: false, enabled: false, mappings: [], paused: false), .transform(customPrint.output), "Custom Print release stays paired")
        let altMapping = KeyMapping(input: extra, output: output)
        check(policy.route(extra, down: true, repeating: false, enabled: true, mappings: [altMapping], paused: false), .transform(output), "Unrelated modified Print keeps its shortcut")
        _ = policy.drain()
        for crossed in [KeyMapping(input: input, output: ctrlOutput), KeyMapping(input: ctrlInput, output: output)] {
            check(policy.route(crossed.input, down: true, repeating: false, enabled: true, mappings: [crossed], paused: false), .transform(crossed.output), "Crossed screenshot chords remain explicit custom shortcuts")
            check(policy.route(crossed.input, down: false, repeating: false, enabled: true, mappings: [crossed], paused: false), .transform(crossed.output), "Crossed screenshot shortcut release remains paired")
        }
        let normalized = DialKeyChord(keyCode: 105, modifiers: CGEventFlags.maskAlphaShift.rawValue | CGEventFlags.maskSecondaryFn.rawValue)
        precondition(normalized == input, "Caps Lock and Fn ignored")
        let firstID = store.mappings[0].id
        store.setEnabled(id: firstID, on: false)
        check(policy.route(input, down: true, repeating: false, enabled: true, mappings: store.mappings, paused: false), .pass, "Individual disable")
        let alternate = DialKeyChord(keyCode: 107, modifiers: 0)
        store.assign(input: alternate, output: output)
        store.assign(input: alternate, output: ctrlOutput)
        precondition(store.mappings.count == 3 && store.mappings.last?.output == ctrlOutput, "Assignment replaces an existing chord")
        store.assign(input: DialKeyChord(keyCode: 55, modifiers: 0), output: output)
        precondition(store.mappings.count == 3, "Modifier-only input rejected")
        store.enabled = false
        let restored = KeyboardMappings(defaults: defaults)
        precondition(!restored.enabled && restored.mappings.count == 3 && restored.mappings[0].id == firstID && !restored.mappings[0].enabled, "Persistence")
        restored.remove(id: firstID)
        precondition(KeyboardMappings(defaults: defaults).mappings.count == 2, "Removal persists")
        for code in UInt16(54)...UInt16(63) {
            precondition(DialKeyChord(keyCode: code, modifiers: 0).isModifierOnly, "Modifier identification")
        }
        print("Keyboard mapping policy and persistence checks passed")
    }
}
