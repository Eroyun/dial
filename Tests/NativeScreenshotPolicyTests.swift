import Foundation
import CoreGraphics

@main
struct NativeScreenshotPolicyTests {
    static func main() throws {
        let desktop = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)
        let preferred = URL(fileURLWithPath: "/Users/test/Pictures", isDirectory: true)
        let selected = NativeScreenshotPolicy.outputDirectory(preference: preferred.path,
            desktopDirectory: desktop, isWritableDirectory: { $0 == preferred })
        precondition(selected == preferred.standardizedFileURL)

        let fallback = NativeScreenshotPolicy.outputDirectory(preference: "relative/folder",
            desktopDirectory: desktop, isWritableDirectory: { $0 == desktop })
        precondition(fallback == desktop.standardizedFileURL, "A non-absolute setting falls back to Desktop")
        let unavailable = NativeScreenshotPolicy.outputDirectory(preference: nil,
            desktopDirectory: desktop, isWritableDirectory: { _ in false })
        precondition(unavailable == nil, "Do not invent a destination when Desktop is unavailable")

        let destination = URL(fileURLWithPath: "/Users/test/Desktop/Dial Screenshot test-id.png")
        precondition(NativeScreenshotPolicy.arguments(copyToClipboard: false, destination: destination)
            == ["-i", "-x", destination.path])
        precondition(NativeScreenshotPolicy.arguments(copyToClipboard: true, destination: nil)
            == ["-i", "-c", "-x"])
        precondition(NativeScreenshotPolicy.arguments(copyToClipboard: false, destination: nil) == nil)

        let directory = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)
        let existing = directory.appendingPathComponent("Dial Screenshot 2026-10-14 at 12.00.00 fixed-id.png")
        let unique = NativeScreenshotPolicy.destination(in: directory,
            timestamp: "2026-10-14 at 12.00.00", identifier: "fixed-id",
            fileExists: { $0 == existing })
        precondition(unique.lastPathComponent == "Dial Screenshot 2026-10-14 at 12.00.00 fixed-id (2).png")

        let printKey = try KeyboardCommand.chord("print")
        let copyPrint = try KeyboardCommand.chord("ctrl+print")
        let fileAction = try KeyboardCommand.parse(["assign", "--key", "print", "--action", "screenshot-selection"])
        let copyAction = try KeyboardCommand.parse(["assign", "--key", "ctrl+print", "--action", "copy-screenshot-selection"])
        let literalShortcut = try KeyboardCommand.parse(["assign", "--key", "print", "--shortcut", "cmd+shift+4"])
        let screenshotShortcut = try KeyboardCommand.chord("cmd+shift+4")
        precondition(fileAction == .assignNative(printKey, .screenshotSelection))
        precondition(copyAction == .assignNative(copyPrint, .copyScreenshotSelection))
        precondition(literalShortcut == .assign(printKey, screenshotShortcut),
            "An explicit shortcut remains a literal key mapping")

        let suite = "Dial.NativeScreenshotPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let defaultsStore = KeyboardMappings(defaults: defaults)
        precondition(defaultsStore.mappings.count == 2)
        precondition(defaultsStore.mappings.first(where: { $0.input == printKey })?.nativeAction == .screenshotSelection)
        precondition(defaultsStore.mappings.first(where: { $0.input == copyPrint })?.nativeAction == .copyScreenshotSelection)

        let custom = KeyMapping(input: printKey, output: try KeyboardCommand.chord("cmd+shift+4"))
        defaults.set(try JSONEncoder().encode([custom]), forKey: "keyboardMappings.v1")
        let existingStore = KeyboardMappings(defaults: defaults)
        precondition(existingStore.mappings.count == 1 && existingStore.mappings[0].nativeAction == nil)
        precondition(existingStore.mappings[0].output == custom.output, "Existing custom mappings are not migrated")
        print("Native screenshot path and shortcut compatibility checks passed")
    }
}
