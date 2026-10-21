import Foundation
import CoreGraphics

/// A headless preference interface. It never starts display discovery or an event tap.
enum KeyboardCommand {
    static let preferenceDomain = "io.github.eroyun.dial"
    static let changedNotification = "io.github.eroyun.dial.keyboard.changed"
    static let openNotification = "io.github.eroyun.dial.keyboard.open"

    enum Plan: Equatable {
        case help, list, open
        case assign(DialKeyChord, DialKeyChord)
        case assignNative(DialKeyChord, KeyboardNativeAction)
        case remove(DialKeyChord)
        case enable(Bool, DialKeyChord?)
        case numlock(Bool)
        case numpadMode(String)
    }
    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }
    static let actions = [
        "screenshot-screen": "cmd+shift+3",
        "copy-screenshot-screen": "ctrl+cmd+shift+3",
        "screenshot-options": "cmd+shift+5"
    ]

    static func chord(_ text: String) throws -> DialKeyChord {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, !key.isEmpty else { throw Invalid("Empty key chord; use numpad-add for the keypad + key") }
        var modifiers: UInt64 = 0
        let modifierNames: [String: UInt64] = [
            "ctrl": CGEventFlags.maskControl.rawValue, "control": CGEventFlags.maskControl.rawValue,
            "cmd": CGEventFlags.maskCommand.rawValue, "command": CGEventFlags.maskCommand.rawValue,
            "shift": CGEventFlags.maskShift.rawValue,
            "alt": CGEventFlags.maskAlternate.rawValue, "option": CGEventFlags.maskAlternate.rawValue,
            "opt": CGEventFlags.maskAlternate.rawValue
        ]
        for name in parts.dropLast() {
            guard let flag = modifierNames[name] else { throw Invalid("Unknown modifier: \(name)") }
            guard modifiers & flag == 0 else { throw Invalid("Duplicate modifier: \(name)") }
            modifiers |= flag
        }
        let code: UInt16
        if key.hasPrefix("code:") {
            let value = String(key.dropFirst(5))
            let digits = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
            guard let number = UInt16(digits, radix: value.hasPrefix("0x") ? 16 : 10), number <= 127 else {
                throw Invalid("Key code must be decimal or hexadecimal in the range 0...127")
            }
            code = number
        } else {
            guard let number = keyNames[key] else { throw Invalid("Unknown key: \(key); use help for supported names") }
            code = number
        }
        guard ![UInt16(72), 73, 74, 127].contains(code) else { throw Invalid("Media and power keys are unsupported") }
        let result = DialKeyChord(keyCode: code, modifiers: modifiers)
        guard !result.isModifierOnly else { throw Invalid("Modifier-only keys are unsupported") }
        return result
    }

    static let keyNames: [String: UInt16] = {
        var names: [String: UInt16] = [:]
        for code in UInt16(0)...UInt16(126) {
            let label = DialKeyChord.name(for: code)
            if !label.hasPrefix("Key "), !label.hasPrefix("Keypad "), code != 105,
               !(54...63).contains(code) {
                names[label.lowercased().replacingOccurrences(of: " ", with: "-")] = code
            }
        }
        let aliases: [String: UInt16] = [
            "print":105, "print-screen":105, "printscreen":105, "prtsc":105, "f13":105,
            "scroll":107, "scroll-lock":107, "scrolllock":107, "f14":107,
            "enter":36, "esc":53, "backspace":51, "delete-forward":117,
            "left":123, "right":124, "down":125, "up":126, "minus":27, "-":27,
            "equal":24, "equals":24, "comma":43, "period":47, "slash":44,
            "backslash":42, "semicolon":41, "quote":39, "backtick":50,
            "left-bracket":33, "right-bracket":30,
            "numpad-decimal":65, "numpad-multiply":67, "numpad-add":69,
            "numpad-clear":71, "numlock":71, "num-lock":71, "numpad-divide":75, "numpad-enter":76,
            "numpad-subtract":78, "numpad-equal":81,
            "numpad-0":82, "numpad-1":83, "numpad-2":84, "numpad-3":85,
            "numpad-4":86, "numpad-5":87, "numpad-6":88, "numpad-7":89,
            "numpad-8":91, "numpad-9":92
        ]
        names.merge(aliases) { _, new in new }
        for (name, code) in aliases where name.hasPrefix("numpad-") {
            names[name.replacingOccurrences(of: "numpad-", with: "keypad-")] = code
        }
        return names
    }()

    /// Strict, pure planning: invalid requests cannot partially change preferences.
    static func parse(_ arguments: [String]) throws -> Plan {
        guard let verb = arguments.first else { throw Invalid("Expected a keyboard command") }
        var rest = Array(arguments.dropFirst())
        if ["help", "list", "inspect", "open"].contains(verb) {
            guard rest.isEmpty else { throw Invalid("\(verb) accepts no arguments") }
            return verb == "help" ? .help : verb == "open" ? .open : .list
        }
        if verb == "numlock" {
            guard rest.count == 1, rest[0] == "on" || rest[0] == "off" else { throw Invalid("numlock requires on or off") }
            return .numlock(rest[0] == "on")
        }
        if verb == "numpad-mode" {
            guard rest.count == 1, rest[0] == "navigation" || rest[0] == "disabled" else { throw Invalid("numpad-mode requires navigation or disabled") }
            return .numpadMode(rest[0])
        }
        var on: Bool?
        if verb == "enable" {
            guard let value = rest.first, value == "true" || value == "false" else { throw Invalid("enable requires true or false") }
            on = value == "true"
            rest.removeFirst()
        }
        guard ["assign", "remove", "enable"].contains(verb) else { throw Invalid("Unknown keyboard command: \(verb)") }
        var options: [String: String] = [:]
        while !rest.isEmpty {
            let flag = rest.removeFirst()
            guard ["--key", "--action", "--shortcut"].contains(flag), options[flag] == nil,
                  let value = rest.first, !value.hasPrefix("--") else {
                throw Invalid("Unknown, repeated, or incomplete option: \(flag)")
            }
            options[flag] = value
            rest.removeFirst()
        }
        if verb == "enable" {
            guard options.keys.allSatisfy({ $0 == "--key" }) else { throw Invalid("enable accepts only --key") }
            return .enable(on!, try options["--key"].map(chord))
        }
        guard let inputText = options["--key"] else { throw Invalid("\(verb) requires --key") }
        let input = try chord(inputText)
        if verb == "remove" {
            guard options.count == 1 else { throw Invalid("remove accepts only --key") }
            return .remove(input)
        }
        guard options.count == 2, (options["--action"] != nil) != (options["--shortcut"] != nil) else {
            throw Invalid("assign requires exactly one of --action or --shortcut")
        }
        if let action = options["--action"] {
            if let nativeAction = KeyboardNativeAction(rawValue: action) { return .assignNative(input, nativeAction) }
            guard let shortcut = actions[action] else { throw Invalid("Unknown action: \(action)") }
            return .assign(input, try chord(shortcut))
        }
        return .assign(input, try chord(options["--shortcut"]!))
    }

    static func apply(_ plan: Plan, to store: KeyboardMappings) throws {
        switch plan {
        case let .assignNative(input, action): store.assign(input: input, action: action)
        case let .assign(input, output): store.assign(input: input, output: output)
        case let .remove(input):
            // Removal is idempotent, including an already absent key.
            for mapping in store.mappings where mapping.input == input { store.remove(id: mapping.id) }
        case let .enable(on, input):
            if let input = input {
                guard let mapping = store.mappings.first(where: { $0.input == input }) else { throw Invalid("No mapping exists for \(input.label)") }
                store.setEnabled(id: mapping.id, on: on)
            } else { store.enabled = on }
        case let .numlock(on): store.numLockOn = on
        case let .numpadMode(mode): store.numpadMode = mode
        default: break
        }
    }

    static func snapshot(_ store: KeyboardMappings) -> [String: Any] {
        ["enabled": store.enabled, "numLockOn": store.numLockOn, "numpadMode": store.numpadMode, "activation": "configuration-only; running engine and permissions not verified",
         "mappings": store.mappings.sorted {
             $0.input.keyCode == $1.input.keyCode ? $0.input.modifiers < $1.input.modifiers : $0.input.keyCode < $1.input.keyCode
         }.map { mapping -> [String: Any] in
             var entry: [String: Any] = ["input": describe(mapping.input), "output": describe(mapping.output), "enabled": mapping.enabled,
              "blockedByNumLock": !store.numLockOn && store.numpadMode == "disabled" && mapping.input.isKeypadKey,
              "effectiveEnabled": store.enabled && mapping.enabled && !(!store.numLockOn && store.numpadMode == "disabled" && mapping.input.isKeypadKey)]
             if let action = mapping.nativeAction {
                 entry["nativeAction"] = action.rawValue
                 entry["actionLabel"] = action.displayName
                 entry["outputRole"] = "backward-compatible identity chord; native action consumes input"
             }
             return entry
         }]
    }
    static func describe(_ chord: DialKeyChord) -> [String: Any] {
        ["keyCode": Int(chord.keyCode), "modifiers": chord.modifiers, "label": chord.label]
    }
    static var help: [String: Any] {
        ["schemaVersion":1, "preferenceDomain":preferenceDomain,
         "commands":["help", "list", "inspect", "assign --key CHORD (--action ACTION | --shortcut CHORD)", "remove --key CHORD", "enable true|false [--key CHORD]", "numlock on|off", "numpad-mode navigation|disabled", "open"],
         "actions":actions, "nativeActions":Dictionary(uniqueKeysWithValues: KeyboardNativeAction.allCases.map { ($0.rawValue, $0.displayName) }), "keys":keyNames.mapValues(Int.init),
         "modifierAliases":["ctrl", "control", "cmd", "command", "shift", "alt", "opt", "option"],
         "relatedCapabilities":["aulaClockStatus":"--aula-clock status", "aulaClockSync":"--aula-clock sync --timezone TIMEZONE", "captureStatus":"--capture status", "scrollingScreenshot":"--capture scroll", "copyScrollingScreenshot":"--capture copy-scroll"],
         "numpadDefaultMode":"disabled",
         "keyCodeSyntax":"code:105 or code:0x69; modifiers may prefix with +",
         "examples":["--keyboard assign --key print --action screenshot-selection", "--keyboard assign --key ctrl+print --action copy-screenshot-selection", "--keyboard assign --key scroll --action scrolling-screenshot", "--keyboard assign --key ctrl+scroll --action copy-scrolling-screenshot", "--keyboard assign --key numpad-1 --shortcut cmd+c", "--keyboard list"],
         "limits":["Print aliases F13 (key code 105); physical keyboard identity is unconfirmed", "Scroll Lock aliases F14 (key code 107); physical keyboard identity is unconfirmed until a native key press is observed", "NumLock software state does not verify a physical keyboard LED", "No per-device mappings, media keys, modifier-only mappings, or headless recording", "open sends a request to a running GUI; it does not launch or verify delivery", "Native scrolling capture requires running Dial and Screen Recording permission; ordinary shortcut mappings do not require capture permission", "Stored configuration does not establish engine activation or permissions"],
         "exitCodes":["0":"success", "1":"runtime failure", "2":"invalid request"]]
    }
    static func emit(_ payload: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let output = String(data: data, encoding: .utf8) { print(output) }
    }

    /// Pass CommandLine.arguments.dropFirst(). Bare --keyboard retains the GUI launch path.
    static func runIfRequested(arguments: [String]) -> Int32? {
        if arguments == ["--help"] || arguments == ["--capabilities"] {
            emit(["ok": true, "app": "Dial", "schemaVersion": 1,
                  "keyboard": help,
                  "aulaScreen": ["commands": ["--aula-clock status", "--aula-clock sync --timezone TIMEZONE [--device REGISTRY_ID]"],
                                 "selection": "automatic for one compatible wired keyboard; explicit registry ID for multiple",
                                 "dateFormat": "firmware date order has no documented control"],
                  "panel": ["openCommand": "--panel open"],
                  "documentation": "/Applications/Dial.app/Contents/Resources/KeyboardAutomation.md"])
            return 0
        }
        if arguments == ["--panel", "open"] {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.eroyun.dial.panel.open"), object: nil, userInfo: nil, deliverImmediately: true)
            emit(["ok": true, "openRequestSent": true, "deliveryVerified": false])
            return 0
        }
        guard arguments.first == "--keyboard", arguments.count > 1 else { return nil }
        do {
            let plan = try parse(Array(arguments.dropFirst()))
            if plan == .help { emit(["ok":true, "help":help]); return 0 }
            if plan == .open {
                DistributedNotificationCenter.default().postNotificationName(Notification.Name(openNotification), object: nil, userInfo: nil, deliverImmediately: true)
                emit(["ok":true, "openRequestSent":true, "deliveryVerified":false]); return 0
            }
            // A bundled executable must use its own standard domain. Foundation rejects
            // constructing a suite with the current app's bundle identifier.
            let domainDefaults = Bundle.main.bundleIdentifier == preferenceDomain ? UserDefaults.standard : UserDefaults(suiteName: preferenceDomain)
            guard let defaults = domainDefaults else {
                emit(["ok":false, "error":"Cannot open keyboard preference domain"]); return 1
            }
            let store = KeyboardMappings(defaults: defaults)
            try apply(plan, to: store)
            if plan != .list {
                guard defaults.synchronize() else { emit(["ok":false, "error":"Preference synchronization failed"]); return 1 }
                DistributedNotificationCenter.default().postNotificationName(Notification.Name(changedNotification), object: nil, userInfo: nil, deliverImmediately: true)
            }
            emit(["ok":true, "state":snapshot(store)])
            return 0
        } catch {
            emit(["ok":false, "error":String(describing: error), "helpCommand":"--keyboard help"])
            return error is Invalid ? 2 : 1
        }
    }
}
