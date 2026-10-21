import AppKit
import CDDC
import Observation

@Observable
final class ExternalDisplay: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    @ObservationIgnored fileprivate let identity: DisplayIdentity
    var detail: String = ""
    /// Whether the size list is open in the panel.
    var showingSizes = false
    /// When the size list last closed, so the click that closed it doesn't reopen it.
    @ObservationIgnored var sizesClosedAt = Date.distantPast
    /// 0...1, nil until read (or unsupported).
    var brightness: Double?
    var volume: Double?
    var supportsDDC: Bool { ddc != nil }
    /// The screen has a control channel but never answered on it (some adapters and docks block it).
    private(set) var unanswered = false
    /// The screen can't change its own brightness, so Dial dims the picture instead.
    private(set) var dimsPicture = false
    @ObservationIgnored private var curve: (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])?
    private(set) var modes: [DisplayMode] = []
    @ObservationIgnored private var allModes: [DisplayMode] = []
    private(set) var current: DisplayMode?
    @ObservationIgnored private var expectedDialModeChange: String?
    @ObservationIgnored private var lastRestoreSkipDiagnostic: String?
    @ObservationIgnored private var active = true
    @ObservationIgnored private(set) var ddcResponded = false
    var currentModeKey: String? { current.map { "\($0.sizeKey)@\($0.hz)" } }

    /// Distinct "looks like" sizes, largest first. When a size comes both sharp (HiDPI) and
    /// blurry, only the sharp one is offered.
    var resolutions: [DisplayMode] {
        var seen = Set<String>()
        return modes
            .sorted { ($0.width, $0.height, $0.hiDPI ? 1 : 0) > ($1.width, $1.height, $1.hiDPI ? 1 : 0) }
            .filter { seen.insert($0.sizeLabel).inserted }
    }

    /// The screen's real pixel size, e.g. 3840 × 2160.
    private(set) var nativeSize = ""

    /// Refresh rates available at the current size.
    var refreshRates: [DisplayMode] {
        guard let current else { return [] }
        var seen = Set<Int>()
        return modes.filter { $0.sizeKey == current.sizeKey && seen.insert($0.hz).inserted }.sorted { $0.hz > $1.hz }
    }

    @ObservationIgnored private let ddc: DDCWriter?
    @ObservationIgnored private var maxBrightness: UInt16 = 100
    @ObservationIgnored private var maxVolume: UInt16 = 100

    init(id: CGDirectDisplayID, name: String, ddc: DDC?) {
        self.id = id
        self.name = name
        let captured = DisplayIdentity(id: id)
        self.identity = captured
        self.ddc = ddc.map { control in
            DDCWriter(ddc: control, label: "\(id)") {
                DisplayRefreshPolicy.mayWrite(captured: captured,
                    current: DisplayIdentity(id: id), online: CGDisplayIsOnline(id) != 0)
            }
        }
        refreshDetail()
    }

    /// Read-only identity check for UI visibility; it grants no control access.
    var matchesCurrentIdentity: Bool {
        DisplayRefreshPolicy.mayWrite(captured: identity,
            current: DisplayIdentity(id: id), online: CGDisplayIsOnline(id) != 0)
    }

    private var canWrite: Bool { active && matchesCurrentIdentity }

    func refreshDetail() {
        guard let mode = CGDisplayCopyDisplayMode(id) else {
            current = nil
            modes = []
            allModes = []
            return
        }
        let all = (CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode]) ?? []
        allModes = all.map(DisplayMode.init).filter { $0.mode.isUsableForDesktopGUI() && $0.width >= 1024 }
        var seen = Set<String>()
        modes = allModes
            .filter { seen.insert($0.modeKey).inserted }
            .sorted { ($0.width, $0.hiDPI ? 1 : 0, $0.hz) > ($1.width, $1.hiDPI ? 1 : 0, $1.hz) }
        let now = DisplayMode(mode)
        current = now
        let native = modes.first(where: \.isNative)?.mode ?? mode
        nativeSize = "\(native.pixelWidth) × \(native.pixelHeight)"
        detail = "\(nativeSize) screen"
    }

    /// Switch size, keeping the refresh rate when the new size offers it.
    func select(size: DisplayMode) {
        guard canWrite else { return }
        if current?.sizeKey == size.sizeKey { remember(); return }
        let hz = current?.hz ?? 0
        let candidates = modes.filter { $0.sizeKey == size.sizeKey }
        if apply(candidates.first { $0.hz == hz } ?? candidates.max { $0.hz < $1.hz } ?? size) { remember() }
    }

    func select(refresh: DisplayMode) {
        guard canWrite else { return }
        if current?.modeKey == refresh.modeKey { remember(); return }
        if apply(refresh) { remember() }
    }

    // MARK: Remembered choice
    // macOS sometimes picks a different size or refresh rate when a monitor reconnects or the Mac
    // wakes. The size and rate chosen in Dial are kept per monitor and put back when it returns.

    private var memoryKey: String {
        "mode-\(identity.vendor)-\(identity.model)-\(identity.serial)"
    }
    private var fingerprintKey: String { memoryKey + "-fingerprint" }

    var savedMode: String? { UserDefaults.standard.string(forKey: memoryKey) }

    /// Save the mode that macOS currently reports, without applying any display configuration.
    @discardableResult func saveCurrentMode(expectedRefresh: Int? = nil) -> Bool {
        guard canWrite else { return false }
        refreshDetail()
        guard let current, expectedRefresh == nil || current.hz == expectedRefresh else { return false }
        remember()
        return true
    }

    func remember() {
        guard canWrite, let current else { return }
        UserDefaults.standard.set(current.modeKey, forKey: memoryKey)
        UserDefaults.standard.set(current.fingerprint, forKey: fingerprintKey)
    }

    func restore() {
        guard canWrite else { return }
        guard let saved = UserDefaults.standard.string(forKey: memoryKey), let current else { return }
        let savedFingerprint = UserDefaults.standard.string(forKey: fingerprintKey)
        if saved == current.modeKey, savedFingerprint == nil {
            // Existing preferences migrate only when macOS is already showing that choice.
            // No display configuration is needed, and the exact current mode is known.
            UserDefaults.standard.set(current.fingerprint, forKey: fingerprintKey)
        }
        let candidates = allModes.map { DisplayModeDescriptor(key: $0.modeKey, fingerprint: $0.fingerprint) }
        guard let index = DisplayModeSelectionPolicy.restoreIndex(savedKey: saved,
            savedFingerprint: savedFingerprint, currentKey: current.modeKey, candidates: candidates)
        else {
            if saved != current.modeKey {
                let counts = DisplayModeSelectionPolicy.matchCounts(savedKey: saved, candidates: candidates)
                let reason = counts.raw == 0 ? "saved mode unavailable" : "distinct saved-mode variants"
                let diagnostic = "\(name) [CG \(id)]: left current mode in place (\(reason)); current \(current.modeKey) [\(current.fingerprint)], saved \(saved) [\(savedFingerprint ?? "legacy/no fingerprint")], candidates raw=\(counts.raw) distinct=\(counts.distinct)"
                if diagnostic != lastRestoreSkipDiagnostic {
                    log(diagnostic)
                    lastRestoreSkipDiagnostic = diagnostic
                }
            } else {
                lastRestoreSkipDiagnostic = nil
            }
            return
        }
        lastRestoreSkipDiagnostic = nil
        let mode = allModes[index]
        if savedFingerprint != nil && mode.fingerprint != savedFingerprint {
            log("\(name): exact saved mode unavailable; using sole available \(saved) mode (HDR preference not captured)")
        }
        log("restoring \(saved) on \(name) (was \(current.modeKey))")
        let exact = mode.fingerprint == savedFingerprint
        if !apply(mode, expectedFingerprint: exact ? savedFingerprint : nil) {
            log("\(name): could not verify restore of \(saved)")
        }
    }

    @discardableResult private func apply(_ mode: DisplayMode, expectedFingerprint: String? = nil) -> Bool {
        guard canWrite else { return false }
        expectedDialModeChange = nil
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard canWrite, CGConfigureDisplayWithDisplayMode(config, id, mode.mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        expectedDialModeChange = "\(mode.sizeKey)@\(mode.hz)"
        guard canWrite, CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            expectedDialModeChange = nil
            CGCancelDisplayConfiguration(config)
            return false
        }
        refreshDetail()
        let verifiedKey = current?.modeKey == mode.modeKey
        let verifiedExact = expectedFingerprint == nil || current?.fingerprint == expectedFingerprint
        if !verifiedKey || !verifiedExact {
            // A same-key result still came from Dial's configuration. Consume its
            // callback so it cannot replace the saved exact preference.
            if !verifiedKey { expectedDialModeChange = nil }
            if verifiedKey && !verifiedExact {
                log("\(name): requested exact mode \(expectedFingerprint ?? "unknown"), display reports \(current?.fingerprint ?? "no mode") (HDR preference not represented)")
            } else {
                log("\(name): requested \(mode.modeKey), display reports \(currentModeKey ?? "no mode")")
            }
        }
        return verifiedKey && verifiedExact
    }

    /// A callback can follow a configuration Dial just applied. Consume only the mode Dial
    /// requested; a different observed mode may be a user's change in System Settings.
    func consumeOwnModeChange() -> Bool {
        guard canWrite else { return false }
        guard let expectedDialModeChange else { return false }
        self.expectedDialModeChange = nil
        guard let mode = CGDisplayCopyDisplayMode(id) else { return false }
        let observed = DisplayMode(mode)
        return "\(observed.sizeKey)@\(observed.hz)" == expectedDialModeChange
    }

    /// Reads brightness and volume. Right after a hotplug or wake the monitor often doesn't answer
    /// yet, so a missing reply is asked again a few times.
    func load(attempt: Int = 0) {
        guard canWrite else { return }
        if attempt == 0 {
            unanswered = false
            // A read on a blocked channel can hang rather than fail, so give up on a clock too.
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                guard self.canWrite else { return }
                if self.brightness == nil && self.volume == nil {
                    self.unanswered = true
                    log("\(self.name): no reply to brightness or volume")
                    self.dimPicture()
                }
            }
        }
        ddc?.read(.brightness) { reply in
            DispatchQueue.main.async {
                guard self.canWrite else { return }
                guard let reply else { return self.retryLoad(after: attempt) }
                guard !self.dimsPicture else { return } // too late: Dial already dims this screen
                self.ddcResponded = true
                self.maxBrightness = reply.max
                self.brightness = Double(reply.current) / Double(reply.max)
            }
        }
        ddc?.read(.volume) { reply in
            DispatchQueue.main.async {
                guard self.canWrite else { return }
                guard let reply else { return self.retryLoad(after: attempt) }
                self.maxVolume = reply.max
                self.ddcResponded = true
                self.volume = Double(reply.current) / Double(reply.max)
            }
        }
    }

    @ObservationIgnored private var retryScheduled = false

    private func retryLoad(after attempt: Int) {
        guard canWrite, attempt < 4, !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard self.canWrite else { return }
            self.retryScheduled = false
            if self.brightness == nil || self.volume == nil { self.load(attempt: attempt + 1) }
        }
    }

    func setBrightness(_ value: Double) {
        guard canWrite else { return }
        let value = value.clamped
        brightness = value
        if dimsPicture {
            applyDimming()
            UserDefaults.standard.set(value, forKey: dimKey)
        } else {
            ddc?.set(.brightness, UInt16((value * Double(maxBrightness)).rounded()))
        }
    }

    /// Switches brightness to dimming the picture, starting from the level used last time.
    func dimPicture() {
        guard canWrite, !dimsPicture else { return }
        dimsPicture = true
        brightness = UserDefaults.standard.object(forKey: dimKey) as? Double ?? 1
        applyDimming()
        log("\(name): dimming the picture instead")
    }

    /// Scales the screen's own colour curve, so its calibration is kept. macOS resets the curve
    /// when the screen reconnects (the store reapplies it) and when Dial quits.
    func applyDimming() {
        guard canWrite, dimsPicture, let brightness else { return }
        if curve == nil {
            var red = [CGGammaValue](repeating: 0, count: 256), green = red, blue = red
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count) == .success, count > 0 else { return }
            let n = Int(count)
            curve = (Array(red.prefix(n)), Array(green.prefix(n)), Array(blue.prefix(n)))
        }
        guard let curve, canWrite else { return }
        let scale = CGGammaValue(0.1 + 0.9 * brightness) // never all the way to black
        CGSetDisplayTransferByTable(id, UInt32(curve.red.count), curve.red.map { $0 * scale }, curve.green.map { $0 * scale }, curve.blue.map { $0 * scale })
    }

    private var dimKey: String { "dim" + memoryKey.dropFirst("mode".count) }

    /// Called only when a verified replacement has taken over this same display identity.
    func restoreGammaBeforeRebind() {
        guard canWrite, dimsPicture, let curve else { return }
        CGSetDisplayTransferByTable(id, UInt32(curve.red.count), curve.red, curve.green, curve.blue)
    }

    func invalidate() { active = false; ddc?.stopAndDrain {} }

    func setVolume(_ value: Double) {
        guard canWrite else { return }
        let value = value.clamped
        volume = value
        ddc?.set(.volume, UInt16((value * Double(maxVolume)).rounded()))
    }
}

@Observable
final class DisplayStore {
    private(set) var displays: [ExternalDisplay] = []
    @ObservationIgnored private var scheduledRefreshes: [DispatchWorkItem] = []
    @ObservationIgnored private var pendingSimpleReason: DisplayRefreshReason?
    @ObservationIgnored private var mirrorInventoryUntil = Date.distantPast
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var settlingGeneration = 0
    @ObservationIgnored private var settling = false
    @ObservationIgnored private var wakeDuringSettling = false
    @ObservationIgnored private var modeChangedDuringSettling = Set<CGDirectDisplayID>()
    @ObservationIgnored private var modeCallbackIDsDuringSettling = Set<CGDirectDisplayID>()
    @ObservationIgnored private var pendingModeChangeIDs = Set<CGDirectDisplayID>()
    @ObservationIgnored private var lastObservedModes: [CGDirectDisplayID: String] = [:]
    @ObservationIgnored private var reconnectIDs = Set<CGDirectDisplayID>()
    @ObservationIgnored private var reboundIDs = Set<CGDirectDisplayID>()

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { id, flags, context in
        guard let context, !flags.contains(.beginConfigurationFlag) else { return }
        let store = Unmanaged<DisplayStore>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { [weak store] in
            guard let store else { return }
            // A callback may carry setMode together with topology or mirror flags.
            // Preserve its target even when another flag decides the refresh reason.
            if flags.contains(.setModeFlag) { store.noteModeCallback(for: id) }
            if flags.contains(.addFlag) || flags.contains(.removeFlag) || flags.contains(.enabledFlag) || flags.contains(.disabledFlag) {
                store.beginSettling(.topology, displayID: id)
            } else if flags.contains(.mirrorFlag) || flags.contains(.unMirrorFlag) {
                store.mirrorInventoryUntil = Date().addingTimeInterval(2)
                store.scheduleInventoryRefresh(supersedeMode: true)
            } else if flags.contains(.setModeFlag) {
                store.scheduleModeRefresh(for: id)
            } else {
                // Move, main-display, mirror and desktop-shape callbacks still update the
                // inventory, but do not change the saved mode preference.
                store.scheduleInventoryRefresh()
            }
        }
    }

    init() {
        let status = CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        if status != .success { log("display callback registration failed: \(status.rawValue)") }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.beginSettling(.wake)
        }
        refresh(reason: .initial)
    }

    deinit {
        scheduledRefreshes.forEach { $0.cancel() }
        displays.forEach { $0.invalidate() }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
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

    private func beginSettling(_ reason: DisplayRefreshReason, displayID: CGDirectDisplayID? = nil) {
        if reason == .topology, let displayID { reconnectIDs.insert(displayID) }
        if reason == .wake { wakeDuringSettling = true }
        settling = true
        settlingGeneration += 1
        modeCallbackIDsDuringSettling.formUnion(pendingModeChangeIDs)
        pendingModeChangeIDs.removeAll()
        pendingSimpleReason = nil
        let generation = settlingGeneration
        scheduledRefreshes.forEach { $0.cancel() }
        scheduledRefreshes = DisplayRefreshPolicy.settleDelays.enumerated().map { index, delay in
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.settlingGeneration == generation else { return }
                self.refresh(reason: self.wakeDuringSettling ? .wake : .topology,
                             finalSettlingPass: index == DisplayRefreshPolicy.settleDelays.count - 1)
                if index == DisplayRefreshPolicy.settleDelays.count - 1 {
                    if !self.modeChangedDuringSettling.isEmpty {
                        log("mode changed during reconnect/wake on display IDs \(self.modeChangedDuringSettling.sorted()); left current mode in place pending explicit save")
                    }
                    self.settling = false
                    self.wakeDuringSettling = false
                    self.modeChangedDuringSettling.removeAll()
                    // If enumeration failed, refresh did not consume these IDs.
                    // Carry them to the next successful inventory pass.
                    self.pendingModeChangeIDs.formUnion(self.modeCallbackIDsDuringSettling)
                    self.modeCallbackIDsDuringSettling.removeAll()
                    self.reconnectIDs.removeAll()
                    self.reboundIDs.removeAll()
                    self.scheduledRefreshes.removeAll()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private func noteModeCallback(for id: CGDirectDisplayID) {
        if settling { modeCallbackIDsDuringSettling.insert(id) }
        else { pendingModeChangeIDs.insert(id) }
    }

    private func scheduleModeRefresh(for id: CGDirectDisplayID) {
        if Date() < mirrorInventoryUntil {
            if !settling { scheduleInventoryRefresh(supersedeMode: true) }
            return
        }
        if settling {
            guard let existing = displays.first(where: { $0.id == id }),
                  lastObservedModes[id] != nil,
                  !existing.consumeOwnModeChange(),
                  let mode = CGDisplayCopyDisplayMode(id)
            else { return }
            let observed = DisplayMode(mode)
            if "\(observed.sizeKey)@\(observed.hz)" != lastObservedModes[id] {
                modeChangedDuringSettling.insert(id)
            }
            return
        }
        scheduleSimpleRefresh(.modeChange)
    }

    private func scheduleInventoryRefresh(supersedeMode: Bool = false) {
        guard !settling, supersedeMode || pendingSimpleReason != .modeChange else { return }
        scheduleSimpleRefresh(.inventory)
    }

    private func scheduleSimpleRefresh(_ reason: DisplayRefreshReason) {
        scheduledRefreshes.forEach { $0.cancel() }
        pendingSimpleReason = reason
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.settling else { return }
            self.pendingSimpleReason = nil
            self.refresh(reason: reason)
        }
        scheduledRefreshes = [work]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func refresh() { refresh(reason: .modeChange) }

    private func refresh(reason: DisplayRefreshReason, finalSettlingPass: Bool = false) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return }
        let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        let services = AVServiceLocator.externalServices()
        let modeAffectedIDs = pendingModeChangeIDs.union(modeCallbackIDsDuringSettling)
        var next: [ExternalDisplay] = []
        for id in external {
            let existing = displays.first { $0.id == id && $0.identity == DisplayIdentity(id: id) }
            let needsRebind = DisplayRefreshPolicy.shouldRebind(reason: reason, isKnown: existing != nil,
                affectedByReconnect: reconnectIDs.contains(id), alreadyRebound: reboundIDs.contains(id),
                ddcResponded: existing?.ddcResponded ?? false)
            let service = Self.verifiedService(for: id, among: Array(external), in: services)
            if needsRebind, service == nil, let existing, existing.dimsPicture {
                // Preserve its original gamma curve while the I2C proxy is still settling.
                existing.refreshDetail()
                if DisplayRefreshPolicy.shouldRestore(reason: reason, isKnown: true, settling: settling,
                                                      affectedByReconnect: reconnectIDs.contains(id),
                                                      externalModeChangeObserved: modeChangedDuringSettling.contains(id)) {
                    existing.restore()
                }
                if DisplayRefreshPolicy.shouldReapplyDimming(reason: reason,
                    affectedByReconnect: reconnectIDs.contains(id),
                    modeChangeAffected: modeAffectedIDs.contains(id)) { existing.applyDimming() }
                next.append(existing)
                continue
            }
            if let existing, !needsRebind {
                existing.refreshDetail()
                if DisplayRefreshPolicy.shouldRestore(reason: reason, isKnown: true, settling: settling,
                                                      affectedByReconnect: reconnectIDs.contains(id),
                                                      externalModeChangeObserved: modeChangedDuringSettling.contains(id)) {
                    existing.restore()
                }
                if DisplayRefreshPolicy.shouldReapplyDimming(reason: reason,
                    affectedByReconnect: reconnectIDs.contains(id),
                    modeChangeAffected: modeAffectedIDs.contains(id)) { existing.applyDimming() }
                if DisplayRefreshPolicy.shouldAdoptExternalMode(reason: reason, isKnown: true, settling: settling) {
                    let before = existing.savedMode
                    existing.remember()
                    if before != existing.savedMode { log("\(existing.name): remembered external mode \(existing.savedMode ?? "unknown")") }
                }
                next.append(existing)
                continue
            }
            if needsRebind, service != nil { existing?.restoreGammaBeforeRebind() }
            let display = ExternalDisplay(id: id, name: Self.name(of: id) ?? service?.name ?? "Display", ddc: service?.ddc)
            if service == nil {
                if !settling || finalSettlingPass { display.dimPicture() }
            } else { display.load() }
            if DisplayRefreshPolicy.shouldRestore(reason: reason, isKnown: existing != nil, settling: settling,
                                                  affectedByReconnect: reconnectIDs.contains(id),
                                                  externalModeChangeObserved: modeChangedDuringSettling.contains(id)) {
                display.restore()
            }
            if needsRebind, service != nil {
                reboundIDs.insert(id)
                log("\(display.name): rebound controls after \(reason)")
            }
            next.append(display)
        }
        for old in displays where !next.contains(where: { $0 === old }) { old.invalidate() }
        displays = next.sorted { CGDisplayBounds($0.id).minX < CGDisplayBounds($1.id).minX }
        lastObservedModes = Dictionary(uniqueKeysWithValues: displays.compactMap { display in
            display.currentModeKey.map { (display.id, $0) }
        })
        // A successful pass handled these callback targets. Keep any later event
        // and, on failed enumeration, keep the pending targets for a future pass.
        pendingModeChangeIDs.subtract(modeAffectedIDs)
        modeCallbackIDsDuringSettling.subtract(modeAffectedIDs)
    }

    private static func verifiedService(for id: CGDirectDisplayID, among external: [CGDirectDisplayID],
                                        in services: [AVServiceLocator.Match]) -> AVServiceLocator.Match? {
        let identity = DisplayIdentity(id: id)
        let candidates = services.filter { $0.vendor == identity.vendor && $0.product == identity.model }
        let sameModelDisplays = external.filter {
            CGDisplayVendorNumber($0) == CGDisplayVendorNumber(id) && CGDisplayModelNumber($0) == CGDisplayModelNumber(id)
        }
        if identity.serial != 0 {
            let exact = candidates.filter { $0.serial == identity.serial }
            if exact.count == 1 { return exact[0] }
            // Some IOAVService proxies omit serial even when CoreGraphics has one. A unique
            // vendor/model proxy with no conflicting known serial is still unambiguous.
            return candidates.count == 1 && candidates[0].serial == 0 && sameModelDisplays.count == 1 ? candidates[0] : nil
        }
        return candidates.count == 1 && sameModelDisplays.count == 1 ? candidates[0] : nil
    }

    private static func name(of id: CGDirectDisplayID) -> String? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }?.localizedName
    }
}

private extension DisplayIdentity {
    init(id: CGDirectDisplayID) {
        self.init(vendor: Int(CGDisplayVendorNumber(id)),
                  model: Int(CGDisplayModelNumber(id)),
                  serial: Int(CGDisplaySerialNumber(id)))
    }
}

struct DisplayMode: Identifiable {
    let mode: CGDisplayMode
    var id: Int32 { mode.ioDisplayModeID }
    var width: Int { mode.width }
    var height: Int { mode.height }
    var hz: Int { Int(mode.refreshRate.rounded()) }
    var hiDPI: Bool { mode.pixelWidth > mode.width }
    var isNative: Bool { mode.ioFlags & UInt32(kDisplayModeNativeFlag) != 0 }
    var sizeKey: String { "\(width)x\(height)\(hiDPI ? "@2x" : "")" }
    var modeKey: String { "\(sizeKey)@\(hz)" }
    /// Sufficient to distinguish CoreGraphics modes with the same visible size/rate.
    /// It is not a record of the user's HDR setting.
    var fingerprint: String {
        "v1:\(id):\(width)x\(height):\(mode.pixelWidth)x\(mode.pixelHeight):\(hz):\(mode.ioFlags)"
    }
    var sizeLabel: String { "\(width) × \(height)" }

    init(_ mode: CGDisplayMode) { self.mode = mode }
}

extension Double {
    var clamped: Double { Swift.min(1, Swift.max(0, self)) }
}
