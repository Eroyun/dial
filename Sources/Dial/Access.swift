import AppKit
import Security
import Observation

/// Dial's single permission: Accessibility. It lets Dial catch the brightness and volume keys
/// and hold back touches while touch is off. Granting it is noticed within a second.
@Observable
final class Access {
    static let shared = Access()

    private(set) var granted = AXIsProcessTrusted()
    /// Dial sent the user to Settings this session and is waiting for the switch.
    private(set) var asked = false

    @ObservationIgnored private var waiters: [() -> Void] = []
    @ObservationIgnored private var poll: Timer?

    private init() {
        log("launch: accessibility \(granted ? "granted" : "not granted")")
        if !granted { watch() }
    }

    /// Runs `action` now if Dial has permission, otherwise as soon as the user grants it.
    func whenGranted(_ action: @escaping () -> Void) {
        if granted { action() } else { waiters.append(action) }
    }

    /// Opens the Accessibility list in System Settings, where the user turns Dial on.
    func ask() {
        asked = true
        // An entry left by an older Dial build stays switched on in Settings but no longer applies
        // to this copy. Clear it once per build, never again: clearing on every ask removed the
        // entry the user had just turned on.
        let build = Self.signature()
        if UserDefaults.standard.string(forKey: "accessClearedFor") != build {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "io.github.eroyun.dial"]
            try? reset.run()
            reset.waitUntilExit()
            UserDefaults.standard.set(build, forKey: "accessClearedFor")
            log("cleared old accessibility entry (exit \(reset.terminationStatus))")
        }
        // Adds Dial to the list so the user only has to flip its switch.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        log("asked for accessibility")
        watch()
    }

    /// The code signature hash macOS ties the permission to; it changes with every build.
    private static func signature() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return "unknown" }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func watch() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.poll?.invalidate()
            self.poll = nil
            self.granted = true
            log("accessibility granted")
            let waiters = self.waiters
            self.waiters = []
            waiters.forEach { $0() }
        }
    }
}
