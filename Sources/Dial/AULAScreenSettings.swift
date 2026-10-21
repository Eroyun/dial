import Foundation
import SwiftUI
import Observation
import Darwin

@Observable
final class AULAScreenSettings {
    struct Device: Decodable, Identifiable {
        let product: String
        let vendorID: Int
        let productID: Int
        let usagePage: Int
        let usage: Int
        let registryID: String
        let locationID: Int
        var id: String { registryID }
        var label: String { "\(product) · USB \(locationID)" }
        var compatible: Bool {
            vendorID == 0x0C45 && productID == 0x800A && usagePage == 0xFF13 && usage == 1 &&
            !registryID.isEmpty && registryID.allSatisfy { $0.isASCII && $0.isNumber } &&
            (UInt64(registryID) ?? 0) > 0
        }
    }

    private struct Receipt: Decodable {
        let status: String
        let displayVerified: Bool
        let configurationInterfaces: [Device]?
        let matchedConfigInterfaces: Int?
        let reportsWritten: Int?
        let reportsRead: Int?
        let timestamp: String?
        let timezone: String?
        let selectedRegistryID: String?
        let message: String?
    }

    private(set) var busy = false
    private(set) var status = "Connect your AULA with USB to update its screen clock."
    private(set) var devices: [Device] = []
    var selectedDevice = "" {
        didSet {
            if !applyingSelection {
                explicitSelection = !selectedDevice.isEmpty
                if devices.count > 1 && !busy {
                    status = devices.contains { $0.id == selectedDevice } ? "Ready to update the screen clock." : "Choose the keyboard to update."
                }
            }
        }
    }
    var canSync: Bool { !busy && devices.contains { $0.id == selectedDevice } }

    @ObservationIgnored private var explicitSelection = false
    @ObservationIgnored private var applyingSelection = false
    @ObservationIgnored private var job: AULAScreenProcess?
    @ObservationIgnored private let connections = AULAConnectionObserver()
    @ObservationIgnored private var refreshState = AULAConnectionRefreshState()
    @ObservationIgnored private var monitoringGeneration = 0

    // Construction is passive; the owning window calls beginMonitoring() when shown.
    init() {}

    func beginMonitoring() {
        if !refreshState.active {
            refreshState.open()
            monitoringGeneration &+= 1
            let generation = monitoringGeneration
            connections.start { [weak self] in
                guard let self, self.refreshState.active, self.monitoringGeneration == generation else { return }
                self.refresh()
            }
        }
        refresh()
    }

    func endMonitoring() {
        refreshState.close()
        monitoringGeneration &+= 1
        connections.stop()
        cancel()
    }

    func refresh() {
        // Coalesce connection changes (and a quick reopen while cancelling)
        // into one read-only check after the owned child actually exits.
        guard refreshState.request(busy: busy) else { return }
        start(arguments: ["--aula-clock", "status"], syncing: false)
    }

    func sync() {
        guard canSync else { return }
        start(arguments: ["--aula-clock", "sync", "--timezone", TimeZone.current.identifier,
                          "--device", selectedDevice], syncing: true)
    }

    // Only terminates this model's subprocess; no shared process or application is touched.
    func cancel() {
        guard let owned = job else { busy = false; return }
        owned.cancel()
        if busy { status = "Cancelling clock operation…" }
        // Keep the busy guard until this owned child has actually exited, so a
        // quickly reopened window cannot start a second clock operation.
    }

    private func setSelection(_ id: String, explicit: Bool) {
        applyingSelection = true
        selectedDevice = id
        applyingSelection = false
        explicitSelection = explicit
    }

    private func start(arguments: [String], syncing: Bool) {
        guard let executable = Bundle.main.executableURL else {
            status = "Dial’s executable is unavailable."
            return
        }
        let task = AULAScreenProcess(executable: executable, arguments: arguments)
        job = task
        busy = true
        status = syncing ? "Sending time…" : "Checking keyboard…"
        task.run { [weak self, weak task] data, code, error in
            DispatchQueue.main.async {
                guard let self, let task, self.job === task else { return }
                self.job = nil
                self.busy = false
                defer {
                    if self.refreshState.childExited() { self.refresh() }
                }
                if let error {
                    self.status = error
                    if !syncing { self.devices = []; self.setSelection("", explicit: false) }
                    return
                }
                do {
                    guard data.count <= 131_072 else { throw ParseError.invalid }
                    let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                    guard !receipt.displayVerified else { throw ParseError.invalid }
                    if syncing {
                        guard code == 0, receipt.status == "PROTOCOL_ACKNOWLEDGED",
                              receipt.reportsWritten == 4, receipt.reportsRead == 4,
                              receipt.selectedRegistryID == self.selectedDevice,
                              let stamp = receipt.timestamp, let date = ISO8601DateFormatter().date(from: stamp),
                              let zone = receipt.timezone, let timezone = TimeZone(identifier: zone) else {
                            self.status = receipt.message ?? "Time could not be sent. Refresh the keyboard connection."
                            return
                        }
                        let formatter = DateFormatter()
                        formatter.locale = Locale.current
                        formatter.timeZone = timezone
                        formatter.dateFormat = "dd/MM/yyyy HH:mm:ss"
                        self.status = "Time sent · \(formatter.string(from: date))"
                    } else {
                        guard code == 0, ["WIRED_AVAILABLE", "NEEDS_WIRED", "AMBIGUOUS_DEVICE"].contains(receipt.status),
                              receipt.reportsWritten == 0, receipt.reportsRead == 0,
                              let found = receipt.configurationInterfaces,
                              receipt.matchedConfigInterfaces == found.count,
                              found.allSatisfy(\.compatible), Set(found.map(\.id)).count == found.count else {
                            throw ParseError.invalid
                        }
                        self.devices = found.sorted { $0.registryID < $1.registryID }
                        let selection = AULAConnectionSelection.resolve(ids: found.map(\.id), selected: self.selectedDevice, explicit: self.explicitSelection)
                        self.setSelection(selection.id, explicit: selection.explicit)
                        self.status = found.isEmpty ? "Connect your AULA with USB to update its screen clock." :
                            (found.count > 1 && self.selectedDevice.isEmpty ? "Choose the keyboard to update." : "Ready to update the screen clock.")
                    }
                } catch {
                    self.status = "Dial returned an unreadable keyboard response."
                    if !syncing { self.devices = []; self.setSelection("", explicit: false) }
                }
            }
        }
    }

    private enum ParseError: Error { case invalid }
}

struct AULAScreenCard: View {
    let model: AULAScreenSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("AULA screen").fontWeight(.medium)
                        if model.devices.count == 1 {
                            Text(model.devices[0].product).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh keyboard connection").accessibilityLabel("Refresh AULA keyboard connection")
                    .disabled(model.busy)
                Button(model.busy ? "Working…" : "Sync clock") { model.sync() }
                    .disabled(!model.canSync)
            }
            if model.devices.count > 1 {
                Picker("Keyboard", selection: Binding(get: { model.selectedDevice }, set: { model.selectedDevice = $0 })) {
                    Text("Choose a keyboard…").tag("")
                    ForEach(model.devices) { Text($0.label).tag($0.id) }
                }.disabled(model.busy)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}

// Each operation owns one short-lived copy of Dial. Waiting and pipe reads run off
// the main thread. A single 8-second deadline terminates it, with a bounded kill fallback.
private final class AULAScreenProcess {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func run(completion: @escaping (Data, Int32, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            lock.lock()
            if cancelled { lock.unlock(); completion(Data(), 1, "Clock operation cancelled."); return }
            do { try process.run() }
            catch { lock.unlock(); completion(Data(), 1, "Could not start Dial’s clock control."); return }
            lock.unlock()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.stop(timeout: true)
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            lock.lock()
            let error = timedOut ? "Clock control timed out. Check the USB connection." : (cancelled ? "Clock operation cancelled." : nil)
            lock.unlock()
            completion(data, process.terminationStatus, error)
        }
    }

    func cancel() { stop(timeout: false) }

    private func stop(timeout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if timeout {
            guard process.isRunning else { return }
            timedOut = true
        } else { cancelled = true }
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.process.isRunning { Darwin.kill(self.process.processIdentifier, SIGKILL) }
        }
    }
}
