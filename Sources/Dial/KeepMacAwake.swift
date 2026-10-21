import AppKit
import SwiftUI
import Security

/// Only the user's switch is saved. Administrator authorization belongs to the
/// root-owned helper installation, never to a saved password or app session.
@MainActor @Observable
final class KeepMacAwake {
    static let shared = KeepMacAwake()
    private(set) var active = false
    private(set) var busy = false
    private(set) var enabled = UserDefaults.standard.bool(forKey: "keepAwakeEnabled")
    private(set) var message = "Off"
    private var session: AwakeSession?
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.session?.stop() } }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enabled else { return }
            self.start(allowInstallation: false)
        }
    }

    func setEnabled(_ value: Bool) {
        guard !busy else { return }
        enabled = value
        UserDefaults.standard.set(value, forKey: "keepAwakeEnabled")
        if value { start(allowInstallation: true) }
        else if let session {
            busy = true
            message = "Restoring normal sleep…"
            session.stop()
        }
    }

    private func start(allowInstallation: Bool) {
        guard session == nil else { return }
        busy = true
        message = "Starting…"
        AwakeBrokerClient.isInstalled { [weak self] available in
            Task { @MainActor in
                guard let self else { return }
                if available { self.beginSession() }
                else if allowInstallation { self.installHelper() }
                else {
                    self.busy = false
                    self.message = "Helper setup is needed to resume."
                }
            }
        }
    }

    private func installHelper() {
        let command: String
        do { command = try Self.installationCommand() }
        catch { busy = false; message = "Keep-awake setup requires a consistently signed Dial build."; return }
        message = "One-time administrator setup…"
        let script = "do shell script \(AwakeSession.appleScriptQuote(command)) with administrator privileges"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let installer = Process()
            installer.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            installer.arguments = ["-e", script]
            installer.standardOutput = FileHandle.nullDevice
            installer.standardError = FileHandle.nullDevice
            var success = false
            do { try installer.run(); installer.waitUntilExit(); success = installer.terminationStatus == 0 }
            catch { }
            let installed = success
            Task { @MainActor in
                guard let self else { return }
                if installed { self.start(allowInstallation: false) }
                else { self.busy = false; self.message = "Helper setup was cancelled or failed." }
            }
        }
    }

    /// Pin the running app's identity before authorization, rather than trusting a
    /// mutable pathname or a signature selected after the administrator prompt.
    private static func installationCommand() throws -> String {
        struct InvalidSignature: Error {}
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        var running: SecCode?
        var application: SecStaticCode?
        guard Bundle.main.bundleURL.path == DialAwakeBrokerInfo.application,
              SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &application) == errSecSuccess, let application,
              SecStaticCodeCheckValidity(application, strict, nil) == errSecSuccess else { throw InvalidSignature() }
        func hash(_ code: SecStaticCode) throws -> String {
            var information: CFDictionary?
            guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
                  let values = information as? [String: Any],
                  let flags = values[kSecCodeInfoFlags as String] as? NSNumber,
                  flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue == 0,
                  let data = values[kSecCodeInfoUnique as String] as? Data else { throw InvalidSignature() }
            return data.map { String(format: "%02x", $0) }.joined()
        }
        let applicationHash = try hash(application)
        var pinned: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(applicationHash)\"" as CFString, [], &pinned) == errSecSuccess,
              let pinned, SecCodeCheckValidity(running, strict, pinned) == errSecSuccess else { throw InvalidSignature() }
        var broker: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: DialAwakeBrokerInfo.packagedBroker) as CFURL,
                                         [], &broker) == errSecSuccess, let broker,
              SecStaticCodeCheckValidity(broker, strict, nil) == errSecSuccess,
              let command = AwakeBrokerPolicy.installationCommand(applicationHash: applicationHash,
                                                                   brokerHash: try hash(broker)) else { throw InvalidSignature() }
        return command
    }

    private func beginSession() {
        let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DialAwakeHelper")
        let newSession = AwakeSession(helper: worker) { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
        session = newSession
        newSession.start()
    }

    private func receive(_ event: AwakeSession.Event) {
        switch event {
        case .active:
            active = true; busy = false
            message = "On • lid-closed sleep disabled"
        case .stopped:
            active = false; busy = false; session = nil
            message = "Off • normal sleep restored"
        case .cancelled:
            active = false; busy = false; session = nil
            message = "Off"
        case .failed(let detail):
            active = false; busy = false; session = nil
            message = detail
        }
    }
}

struct KeepMacAwakeCard: View {
    private var control: KeepMacAwake { .shared }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer").frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Keep Mac awake").font(.system(size: 12, weight: .semibold))
                Text(control.message).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle("Keep Mac awake", isOn: Binding(
                get: { control.enabled }, set: { control.setEnabled($0) }
            )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(control.busy)
        }.padding(12).card()
        .help("Keeps this Mac awake while Dial runs, even with its lid closed and nothing connected. Uses battery. Turn off before carrying in a bag.")
    }
}
