import AppKit
import Observation

@Observable
final class ExternalDisplay: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    var detail: String = ""
    /// 0...1, nil until read (or unsupported).
    var brightness: Double?
    var volume: Double?
    var supportsDDC: Bool { ddc != nil }

    @ObservationIgnored private let ddc: DDCWriter?
    @ObservationIgnored private var maxBrightness: UInt16 = 100
    @ObservationIgnored private var maxVolume: UInt16 = 100

    init(id: CGDirectDisplayID, name: String, ddc: DDC?) {
        self.id = id
        self.name = name
        self.ddc = ddc.map { DDCWriter(ddc: $0, label: "\(id)") }
        refreshDetail()
    }

    func refreshDetail() {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return }
        let hz = mode.refreshRate > 0 ? " · \(Int(mode.refreshRate.rounded())) Hz" : ""
        detail = "\(mode.width) × \(mode.height)\(hz)"
    }

    func load() {
        ddc?.read(.brightness) { reply in
            DispatchQueue.main.async {
                guard let reply else { return }
                self.maxBrightness = reply.max
                self.brightness = Double(reply.current) / Double(reply.max)
            }
        }
        ddc?.read(.volume) { reply in
            DispatchQueue.main.async {
                guard let reply else { return }
                self.maxVolume = reply.max
                self.volume = Double(reply.current) / Double(reply.max)
            }
        }
    }

    func setBrightness(_ value: Double) {
        let value = value.clamped
        brightness = value
        ddc?.set(.brightness, UInt16((value * Double(maxBrightness)).rounded()))
    }

    func setVolume(_ value: Double) {
        let value = value.clamped
        volume = value
        ddc?.set(.volume, UInt16((value * Double(maxVolume)).rounded()))
    }
}

@Observable
final class DisplayStore {
    private(set) var displays: [ExternalDisplay] = []
    @ObservationIgnored private var pendingRefresh: DispatchWorkItem?

    init() {
        refresh()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            Unmanaged<DisplayStore>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func display(at point: CGPoint) -> ExternalDisplay? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return displays.first { $0.id == id }
    }

    func display(named name: String) -> ExternalDisplay? {
        displays.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? displays.first { name.localizedCaseInsensitiveContains($0.name) || $0.name.localizedCaseInsensitiveContains(name) }
    }

    private func scheduleRefresh() {
        DispatchQueue.main.async {
            self.pendingRefresh?.cancel()
            let work = DispatchWorkItem { self.refresh() }
            self.pendingRefresh = work
            // Displays settle in stages after a hotplug; wait for the dust.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    func refresh() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        let services = AVServiceLocator.externalServices()
        var next: [ExternalDisplay] = []
        for id in external {
            if let existing = displays.first(where: { $0.id == id }) {
                existing.refreshDetail()
                next.append(existing)
                continue
            }
            let service = AVServiceLocator.match(for: id, in: services)
            let display = ExternalDisplay(id: id, name: Self.name(of: id) ?? service?.name ?? "Display", ddc: service?.ddc)
            display.load()
            next.append(display)
        }
        displays = next.sorted { CGDisplayBounds($0.id).minX < CGDisplayBounds($1.id).minX }
    }

    private static func name(of id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }
}

extension Double {
    var clamped: Double { Swift.min(1, Swift.max(0, self)) }
}
