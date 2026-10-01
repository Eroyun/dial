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

    /// Asks macOS to add Dial to the Accessibility list; its prompt has the button to open Settings.
    /// Asking again opens Settings directly, in case that prompt was dismissed.
    func ask() {
        if asked {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        asked = true
        // An entry left by a copy signed differently stays switched on in Settings but no longer
        // applies to this copy. Clear it once per signature, never again: clearing on every ask
        // removed the entry the user had just turned on.
        let signature = Self.signature()
        if UserDefaults.standard.string(forKey: "accessClearedFor") != signature {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "io.github.eroyun.dial"]
            try? reset.run()
            reset.waitUntilExit()
            UserDefaults.standard.set(signature, forKey: "accessClearedFor")
            log("cleared old accessibility entry (exit \(reset.terminationStatus))")
        }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        log("asked for accessibility")
        watch()
    }

    /// What macOS checks the permission against. A build signed with a certificate keeps the same
    /// requirement from build to build; an unsigned (ad hoc) build gets a new one every time.
    private static func signature() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else { return "unknown" }
        return text as String
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
