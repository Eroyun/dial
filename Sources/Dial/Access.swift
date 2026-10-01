import AppKit
import Observation

/// Dial's single permission: Accessibility. It lets Dial catch the brightness and volume keys
/// and hold back touches while touch is off. Granting it is noticed within a second.
@Observable
final class Access {
    static let shared = Access()

    // Settable only so `--snapshot` can render the setup card.
    var granted = AXIsProcessTrusted()

    @ObservationIgnored private var waiters: [() -> Void] = []
    @ObservationIgnored private var poll: Timer?

    private init() {
        if !granted { watch() }
    }

    /// Runs `action` now if Dial has permission, otherwise as soon as the user grants it.
    func whenGranted(_ action: @escaping () -> Void) {
        if granted { action() } else { waiters.append(action) }
    }

    /// Opens the Accessibility list in System Settings, where the user turns Dial on.
    func ask() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        watch()
    }

    private func watch() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.poll?.invalidate()
            self.poll = nil
            self.granted = true
            let waiters = self.waiters
            self.waiters = []
            waiters.forEach { $0() }
        }
    }
}
