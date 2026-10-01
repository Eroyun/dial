import AppKit

/// Keeps exactly one Dial: running once, from the Applications folder.
enum Install {
    static func check() {
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != me }
        // Opening the same copy again: keep the one already running.
        if others.contains(where: { $0.bundleURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }) {
            log("already running; quitting the second copy")
            exit(0)
        }
        // A different copy (usually a newer download): it takes over.
        for other in others {
            log("replacing Dial running from \(other.bundleURL?.path ?? "?")")
            other.terminate()
        }
        offerMove()
    }

    /// Dial opened straight from the disk image or Downloads gets lost after a restart and leaves
    /// stray copies behind, so offer to put it in Applications.
    private static func offerMove() {
        let source = Bundle.main.bundleURL
        let path = source.path
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") || path.contains("/Downloads/") else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Move Dial to Applications?"
        alert.informativeText = "Dial works best from your Applications folder."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let target = URL(fileURLWithPath: "/Applications/Dial.app")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.trashItem(at: target, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            log("move failed: \(error.localizedDescription)")
            let failed = NSAlert()
            failed.messageText = "Couldn't move Dial"
            failed.informativeText = "Drag Dial into the Applications folder yourself, then open it from there."
            failed.runModal()
            return
        }
        log("moved to Applications")
        NSWorkspace.shared.openApplication(at: target, configuration: .init()) { _, _ in exit(0) }
    }
}
