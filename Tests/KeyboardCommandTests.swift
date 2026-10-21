import Foundation
import CoreGraphics

@main
struct KeyboardCommandTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        let printKey = try KeyboardCommand.chord("print")
        precondition(printKey.keyCode == 105 && printKey.modifiers == 0)
        check(try KeyboardCommand.chord("f13") == printKey)
        check(try KeyboardCommand.chord("code:0x69") == printKey)
        check(try KeyboardCommand.chord("code:105") == printKey)
        check(try KeyboardCommand.chord("ctrl+print").modifiers == CGEventFlags.maskControl.rawValue)
        let scrollKey = DialKeyChord(keyCode: 107, modifiers: 0)
        check(try KeyboardCommand.chord("scroll") == scrollKey)
        check(try KeyboardCommand.chord("scroll-lock") == scrollKey)
        check(try KeyboardCommand.chord("scrolllock") == scrollKey)
        check(try KeyboardCommand.chord("f14") == scrollKey)
        check(try KeyboardCommand.chord("ctrl+scroll") == DialKeyChord(keyCode: 107, modifiers: CGEventFlags.maskControl.rawValue))
        check(try KeyboardCommand.chord("numpad-add").keyCode == 69)
        check(try KeyboardCommand.chord("keypad-1").keyCode == 83)
        let plan = try KeyboardCommand.parse(["assign", "--key", "print", "--action", "screenshot-selection"])
        precondition(plan == .assignNative(printKey, .screenshotSelection))
        check(try KeyboardCommand.parse(["assign", "--key", "scroll", "--action", "scrolling-screenshot"]) ==
              .assignNative(scrollKey, .scrollingScreenshot))
        check(try KeyboardCommand.parse(["assign", "--key", "ctrl+scroll", "--action", "copy-scrolling-screenshot"]) ==
              .assignNative(DialKeyChord(keyCode: 107, modifiers: CGEventFlags.maskControl.rawValue), .copyScrollingScreenshot))
        check(try KeyboardCommand.parse(["inspect"]) == .list)
        check(try KeyboardCommand.parse(["open"]) == .open)
        check(try KeyboardCommand.parse(["enable", "false", "--key", "print"]) == .enable(false, printKey))
        check(try KeyboardCommand.parse(["numlock", "off"]) == .numlock(false))
        check(try KeyboardCommand.parse(["numpad-mode", "navigation"]) == .numpadMode("navigation"))
        check(try KeyboardCommand.chord("numlock").keyCode == 71)
        for args in [
            [], ["wat"], ["numlock", "true"], ["numlock", "off", "extra"], ["numpad-mode", "unknown"], ["help", "extra"], ["open", "--key", "print"],
            ["enable", "yes"], ["enable", "true", "--action", "screenshot-screen"],
            ["assign", "--key", "print"],
            ["assign", "--key", "print", "--key", "f14", "--shortcut", "cmd+c"],
            ["assign", "--key", "print", "--action", "screenshot-selection", "--shortcut", "cmd+c"],
            ["assign", "--key", "print", "--action", "unknown"],
            ["assign", "--key", "print", "--shortcut"],
            ["remove", "--key", "print", "--shortcut", "cmd+c"]
        ] {
            do { _ = try KeyboardCommand.parse(args); preconditionFailure("Accepted invalid arguments: \(args)") }
            catch is KeyboardCommand.Invalid { }
        }
        for text in ["cmd+cmd+c", "ctrl+control+c", "cmd", "cmd+", "fn+c", "volume-up", "code:55", "code:128", "code:72", "code:73", "code:74", "code:127", "code:-1", "code:0xFFFF", "c+cmd"] {
            do { _ = try KeyboardCommand.chord(text); preconditionFailure("Accepted invalid chord: \(text)") }
            catch is KeyboardCommand.Invalid { }
        }
        let suite = "Dial.KeyboardCommandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeyboardMappings(defaults: defaults)
        try KeyboardCommand.apply(.numlock(false), to: store)
        try KeyboardCommand.apply(.numpadMode("disabled"), to: store)
        let numpadRestored = KeyboardMappings(defaults: defaults)
        precondition(!numpadRestored.numLockOn && numpadRestored.numpadMode == "disabled")
        try KeyboardCommand.apply(plan, to: store)
        precondition(store.mappings.count == 2)
        try KeyboardCommand.apply(.enable(false, printKey), to: store)
        precondition(!store.mappings.first(where: { $0.input == printKey })!.enabled)
        try KeyboardCommand.apply(plan, to: store)
        precondition(store.mappings.first(where: { $0.input == printKey })!.enabled)
        try KeyboardCommand.apply(.enable(false, nil), to: store)
        let restored = KeyboardMappings(defaults: defaults)
        precondition(!restored.enabled && restored.mappings.count == 2)
        let state = KeyboardCommand.snapshot(restored)
        let mappings = state["mappings"] as! [[String: Any]]
        precondition(mappings.allSatisfy { $0["effectiveEnabled"] as? Bool == false })
        restored.enabled = true
        restored.assign(input: try KeyboardCommand.chord("numpad-1"), output: try KeyboardCommand.chord("cmd+c"))
        let locked = (KeyboardCommand.snapshot(restored)["mappings"] as! [[String: Any]]).first { ($0["input"] as? [String: Any])?["keyCode"] as? Int == 83 }!
        precondition(locked["effectiveEnabled"] as? Bool == false && locked["blockedByNumLock"] as? Bool == true, "Disabled pad eligibility must be reflected in AI inspection")
        restored.remove(id: restored.mappings.first { $0.input.keyCode == 83 }!.id)
        try KeyboardCommand.apply(.remove(printKey), to: restored)
        try KeyboardCommand.apply(.remove(printKey), to: restored)
        precondition(restored.mappings.count == 1)
        do { try KeyboardCommand.apply(.enable(true, printKey), to: restored); preconditionFailure("Enabled absent mapping") }
        catch is KeyboardCommand.Invalid { }
        precondition(KeyboardCommand.runIfRequested(arguments: ["--keyboard"]) == nil)
        precondition(KeyboardCommand.runIfRequested(arguments: []) == nil)
        _ = try JSONSerialization.data(withJSONObject: KeyboardCommand.help, options: [.sortedKeys])
        print("Keyboard command parsing, persistence, and effective configuration checks passed")
    }
}
