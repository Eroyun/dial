import Foundation
import CoreGraphics

@main
struct MappingBrowserTests {
    static func main() {
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        let fixtures = (0..<180).map { index in
            KeyMapping(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                       input: DialKeyChord(keyCode: UInt16(index + 200), modifiers: index.isMultiple(of: 3) ? CGEventFlags.maskControl.rawValue : 0),
                       output: DialKeyChord(keyCode: 21, modifiers: commandShift | (index.isMultiple(of: 3) ? CGEventFlags.maskControl.rawValue : 0)), enabled: !index.isMultiple(of: 4))
        }
        let custom = KeyMapping(input: DialKeyChord(keyCode: 83, modifiers: CGEventFlags.maskAlternate.rawValue),
                                output: DialKeyChord(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue), enabled: false)
        let all = fixtures + [custom]
        precondition(MappingQuery.count(.all, in: all) == 181)
        precondition(MappingQuery.count(.enabled, in: all) == 135)
        precondition(MappingQuery.count(.disabled, in: all) == 46)
        precondition(MappingQuery.results(in: all, search: "screenshot").count == 180)
        precondition(MappingQuery.results(in: all, search: "CTRL cmd SHIFT 4").count == 60)
        precondition(MappingQuery.results(in: all, search: "control command shift 4").count == 60)
        precondition(MappingQuery.results(in: all, search: "⌃ ⌘ ⇧ 4").count == 60)
        precondition(MappingQuery.results(in: all, search: "ctrl+cmd+shift+4").count == 60)
        let plus = KeyMapping(input: DialKeyChord(keyCode: 69, modifiers: 0), output: custom.output)
        let punctuation = KeyMapping(input: DialKeyChord(keyCode: 43, modifiers: 0), output: custom.output)
        precondition(MappingQuery.results(in: all + [plus, punctuation], search: "+").map(\.id) == [plus.id], "A literal plus identifies the keypad plus key")
        precondition(MappingQuery.results(in: all + [plus, punctuation], search: "keypad +").map(\.id) == [plus.id])
        precondition(MappingQuery.results(in: all + [plus, punctuation], search: ",").map(\.id) == [punctuation.id])
        precondition(MappingQuery.results(in: all, search: "option keypad", filter: .disabled).map(\.id) == [custom.id])
        precondition(MappingQuery.results(in: all, search: "alt keypad", filter: .enabled).isEmpty)
        precondition(MappingQuery.results(in: all, search: "cmd c").map(\.id) == [custom.id])
        precondition(MappingQuery.results(in: all, search: "1").map(\.id) == [custom.id], "Digits must not match longer key codes")
        precondition(MappingQuery.results(in: all, search: "scree").count == 180, "Long action prefixes still match")
        let letterA = KeyMapping(input: DialKeyChord(keyCode: 0, modifiers: 0), output: DialKeyChord(keyCode: 8, modifiers: 0))
        let f1 = KeyMapping(input: DialKeyChord(keyCode: 122, modifiers: 0), output: custom.output)
        let f10 = KeyMapping(input: DialKeyChord(keyCode: 109, modifiers: 0), output: custom.output)
        let mainMinus = KeyMapping(input: DialKeyChord(keyCode: 27, modifiers: 0), output: custom.output)
        let keypadMinus = KeyMapping(input: DialKeyChord(keyCode: 78, modifiers: 0), output: custom.output)
        let specific = all + [letterA, f1, f10, mainMinus, keypadMinus]
        precondition(MappingQuery.results(in: specific, search: "a").map(\.id) == [letterA.id], "A must not match action or command text")
        precondition(MappingQuery.results(in: specific, search: "F1").map(\.id) == [f1.id], "F1 must not match F10")
        precondition(MappingQuery.results(in: specific, search: "cmd f1").isEmpty, "Modifiers and key must share a chord")
        precondition(Set(MappingQuery.results(in: specific, search: "-").map(\.id)) == Set([mainMinus.id, keypadMinus.id]))
        precondition(MappingQuery.results(in: specific, search: "keypad -").map(\.id) == [keypadMinus.id])
        precondition(MappingQuery.results(in: specific, search: "keypad −").map(\.id) == [keypadMinus.id])
        let splitShortcut = KeyMapping(input: DialKeyChord(keyCode: 0, modifiers: CGEventFlags.maskControl.rawValue), output: DialKeyChord(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue))
        precondition(MappingQuery.results(in: [splitShortcut], search: "ctrl cmd c").isEmpty, "Do not combine input and output modifiers")
        precondition(MappingQuery.results(in: all, search: "  unknown shortcut  ").isEmpty)
        precondition(MappingQuery.results(in: [], search: "").isEmpty)
        let nativePrint = KeyMapping(input: DialKeyChord(keyCode: 105, modifiers: 0), output: DialKeyChord(keyCode: 105, modifiers: 0), nativeAction: .screenshotSelection)
        let nativeCopy = KeyMapping(input: DialKeyChord(keyCode: 105, modifiers: CGEventFlags.maskControl.rawValue), output: DialKeyChord(keyCode: 105, modifiers: CGEventFlags.maskControl.rawValue), nativeAction: .copyScreenshotSelection)
        precondition(MappingQuery.displayOutput(for: nativePrint) == DialKeyChord(keyCode: 21, modifiers: commandShift))
        precondition(MappingQuery.results(in: [nativePrint, nativeCopy], search: "ctrl cmd shift 4").map(\.id) == [nativeCopy.id])
        for sort in MappingSort.allCases {
            precondition(MappingQuery.results(in: all, sort: sort).map(\.id) == MappingQuery.results(in: Array(all.reversed()), sort: sort).map(\.id), "Sort must not depend on saved order")
        }
        precondition(MappingQuery.results(in: all, sort: .action).first.map { MappingQuery.actionName(for: $0.output) } == "Copy screenshot selection")
        precondition(MappingQuery.results(in: all, filter: .disabled).allSatisfy { !$0.enabled })
        let duplicate = KeyMapping(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, input: custom.input, output: custom.output, enabled: true)
        precondition(MappingQuery.results(in: [duplicate, custom]).map(\.id) == MappingQuery.results(in: [custom, duplicate]).map(\.id), "Identical chords use a stable ID tie break")
        print("Mapping browser: 181-mapping search, preference filters, aliases and deterministic sorting passed")
    }
}
