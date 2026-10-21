import AppKit
import Foundation

enum NativeScreenshotPolicy {
    static let executablePath = "/usr/sbin/screencapture"

    static func outputDirectory(preference: String?, desktopDirectory: URL,
                                isWritableDirectory: (URL) -> Bool) -> URL? {
        if let preference, preference.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: preference, isDirectory: true).standardizedFileURL
            if isWritableDirectory(candidate) { return candidate }
        }
        let fallback = desktopDirectory.standardizedFileURL
        return isWritableDirectory(fallback) ? fallback : nil
    }

    static func arguments(copyToClipboard: Bool, destination: URL?) -> [String]? {
        if copyToClipboard { return ["-i", "-c", "-x"] }
        guard let destination else { return nil }
        return ["-i", "-x", destination.path]
    }

    static func destination(in directory: URL, timestamp: String, identifier: String,
                            fileExists: (URL) -> Bool) -> URL {
        let safeIdentifier = identifier.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let stem = "Dial Screenshot \(timestamp) \(String(safeIdentifier))"
        var candidate = directory.appendingPathComponent(stem + ".png", isDirectory: false)
        var suffix = 2
        while fileExists(candidate) {
            candidate = directory.appendingPathComponent("\(stem) (\(suffix)).png", isDirectory: false)
            suffix += 1
        }
        return candidate
    }
}

/// Starts macOS's own selection UI for the two screenshot-selection shortcuts.
/// The process is owned by Dial, never runs through a shell, and cannot overlap itself.
@MainActor
final class NativeScreenshot {
    static let shared = NativeScreenshot()

    private let fileManager = FileManager.default
    private var process: Process?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        if let process, process.isRunning { process.terminate() }
    }

    func perform(_ action: KeyboardNativeAction) {
        switch action {
        case .screenshotSelection:
            launch(copyToClipboard: false)
        case .copyScreenshotSelection:
            launch(copyToClipboard: true)
        case .scrollingScreenshot, .copyScrollingScreenshot:
            break
        }
    }

    func stop() {
        guard let process, process.isRunning else { self.process = nil; return }
        process.terminate()
    }

    private func launch(copyToClipboard: Bool) {
        if let process, process.isRunning {
            log("Native screenshot selection is already active")
            return
        }
        process = nil

        var destination: URL?
        if !copyToClipboard {
            let desktop = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
            let preference = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            guard let directory = NativeScreenshotPolicy.outputDirectory(preference: preference,
                desktopDirectory: desktop, isWritableDirectory: isWritableDirectory) else {
                log("Native screenshot selection unavailable: no writable screenshot directory")
                return
            }
            destination = NativeScreenshotPolicy.destination(
                in: directory, timestamp: Self.timestamp(), identifier: UUID().uuidString.lowercased(),
                fileExists: { [fileManager] in fileManager.fileExists(atPath: $0.path) })
        }
        guard let arguments = NativeScreenshotPolicy.arguments(copyToClipboard: copyToClipboard,
                                                                destination: destination) else {
            log("Native screenshot selection unavailable: no output path")
            return
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: NativeScreenshotPolicy.executablePath)
        child.arguments = arguments
        child.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                guard let self, self.process === terminated else { return }
                self.process = nil
                if terminated.terminationReason == .exit && terminated.terminationStatus != 0 {
                    log("Native screenshot selection exited with status \(terminated.terminationStatus)")
                }
            }
        }
        process = child
        do {
            try child.run()
        } catch {
            process = nil
            log("Could not start native screenshot selection: \(error.localizedDescription)")
        }
    }

    private func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue && fileManager.isWritableFile(atPath: url.path)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
