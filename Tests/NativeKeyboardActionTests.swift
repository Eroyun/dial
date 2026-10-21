import Foundation
import CoreGraphics

@main
struct NativeKeyboardActionTests {
    static func main() throws {
        let suite = "Dial.NativeKeyboardActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = DialKeyChord(keyCode: 105, modifiers: CGEventFlags.maskShift.rawValue)
        let output = DialKeyChord(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue)
        let old = KeyMapping(input: input, output: output)
        let oldData = try JSONEncoder().encode([old])
        precondition(!String(decoding: oldData, as: UTF8.self).contains("nativeAction"), "Old schema remains decodable")
        defaults.set(oldData, forKey: "keyboardMappings.v1")
        let store = KeyboardMappings(defaults: defaults)
        precondition(store.mappings.count == 1 && store.mappings[0].nativeAction == nil)
        let id = store.mappings[0].id
        store.setEnabled(id: id, on: false)
        store.assign(input: input, action: .scrollingScreenshot)
        precondition(store.mappings.count == 1 && store.mappings[0].id == id && store.mappings[0].enabled)
        precondition(store.mappings[0].output == input && store.mappings[0].nativeAction == .scrollingScreenshot)
        precondition(KeyboardMappings(defaults: defaults).mappings[0].nativeAction == .scrollingScreenshot)
        store.assign(input: input, output: output)
        precondition(store.mappings[0].nativeAction == nil && store.mappings[0].output == output)
        store.assign(input: input, action: .scrollingScreenshot)
        let native = store.mappings[0]
        var policy = KeyboardRoutingPolicy()
        func route(_ chord: DialKeyChord = input, down: Bool = true, repeatKey: Bool = false,
                   enabled: Bool = true, paused: Bool = false, lock: Bool = true,
                   mappings: [KeyMapping] = [native]) -> KeyboardRoutingPolicy.Decision {
            policy.route(chord, down: down, repeating: repeatKey, mappingsEnabled: enabled,
                         mappings: mappings, numLockOn: lock, mode: "disabled", paused: paused)
        }
        precondition(route(enabled: false) == .pass)
        var disabled = native
        disabled.enabled = false
        precondition(route(mappings: [disabled]) == .pass)
        precondition(route(paused: true) == .pass, "Recording owns new native inputs")
        precondition(route(repeatKey: true) == .pass, "Orphan repeat cannot invoke action")
        precondition(route() == .perform(.scrollingScreenshot))
        precondition(route(repeatKey: true, enabled: false, paused: true, mappings: []) == .consume)
        precondition(route(DialKeyChord(keyCode: input.keyCode, modifiers: 0), down: false,
                           enabled: false, paused: true, mappings: []) == .consume, "Release remains consumed after modifier/configuration changes")
        precondition(route() == .perform(.scrollingScreenshot), "Release allows next physical press")
        precondition(policy.drain().isEmpty, "Native held inputs never synthesize recovery releases")
        precondition(route(down: false) == .pass, "Drain clears native held state")
        for action in [KeyboardNativeAction.screenshotSelection, .copyScreenshotSelection] {
            let mapping = KeyMapping(input: input, output: input, nativeAction: action)
            precondition(route(mappings: [mapping]) == .perform(action))
            precondition(route(repeatKey: true, mappings: [mapping]) == .consume)
            precondition(route(down: false, mappings: [mapping]) == .consume)
        }
        let pad = DialKeyChord(keyCode: 83, modifiers: 0)
        let padMapping = KeyMapping(input: pad, output: pad, nativeAction: .scrollingScreenshot)
        precondition(route(pad, lock: false, mappings: [padMapping]) == .consume, "Disabled keypad preempts native action")
        precondition(route(pad, down: false, mappings: [padMapping]) == .consume)
        precondition(route(pad, mappings: [padMapping]) == .perform(.scrollingScreenshot))
        precondition(route(pad, down: false, paused: true, lock: false, mappings: []) == .consume)
        let clear = DialKeyChord(keyCode: 71, modifiers: 0)
        let clearMapping = KeyMapping(input: clear, output: clear, nativeAction: .scrollingScreenshot)
        precondition(route(clear, lock: false, mappings: [clearMapping]) == .perform(.scrollingScreenshot), "Explicit native Clear mapping preempts toggle")
        precondition(policy.drain().isEmpty)
        precondition(route(clear, lock: false, mappings: []) == .toggle)
        _ = policy.drain()
        let chordMapping = KeyMapping(input: pad, output: output)
        precondition(route(pad, mappings: [chordMapping]) == .transform(output))
        precondition(route() == .perform(.scrollingScreenshot))
        precondition(policy.drain() == [output], "Mixed drain releases only actual transformed outputs")
        let plan = try KeyboardCommand.parse(["assign", "--key", "shift+print", "--action", "scrolling-screenshot"])
        precondition(plan == .assignNative(input, .scrollingScreenshot))
        let copyInput = try KeyboardCommand.chord("ctrl+shift+print")
        let copyPlan = try KeyboardCommand.parse(["assign", "--key", "ctrl+shift+print", "--action", "copy-scrolling-screenshot"])
        precondition(copyPlan == .assignNative(copyInput, .copyScrollingScreenshot))
        try KeyboardCommand.apply(copyPlan, to: store)
        let copyMapping = store.mappings.first { $0.input == copyInput }!
        precondition(copyMapping.output == copyInput && copyMapping.nativeAction == .copyScrollingScreenshot)
        precondition(route(copyInput, mappings: [copyMapping]) == .perform(.copyScrollingScreenshot))
        precondition(route(copyInput, repeatKey: true, mappings: [copyMapping]) == .consume)
        precondition(route(copyInput, down: false, mappings: []) == .consume)
        store.remove(id: copyMapping.id)
        try KeyboardCommand.apply(plan, to: store)
        let rows = KeyboardCommand.snapshot(store)["mappings"] as! [[String: Any]]
        precondition(rows[0]["nativeAction"] as? String == "scrolling-screenshot")
        precondition(rows[0]["actionLabel"] as? String == "Scrolling screenshot")
        precondition(rows[0]["output"] != nil, "Legacy output field retained")
        for args in [
            ["assign", "--key", "print", "--action", "scrolling-screenshot", "--shortcut", "cmd+c"],
            ["assign", "--key", "print", "--action", "scrolling-screenshot", "--action", "scrolling-screenshot"],
            ["assign", "--action", "scrolling-screenshot"],
            ["assign", "--key", "print", "--action", "Scrolling-screenshot"]
        ] {
            do { _ = try KeyboardCommand.parse(args); preconditionFailure("Accepted invalid native assignment") }
            catch is KeyboardCommand.Invalid { }
        }
        print("Native keyboard action compatibility, routing, and command checks passed")
    }
}
