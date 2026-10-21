import AppKit
import CoreGraphics

struct ScrollCaptureScopeSelection {
    /// Global Quartz coordinates, with a top-left origin.
    let rect: CGRect
    /// Global Quartz pointer location that identified the selected target.
    let selectionPoint: CGPoint
    /// Frozen bounds of the underlying public window, in global Quartz coordinates.
    let windowBounds: CGRect?
    let application: NSRunningApplication?
    let windowID: CGWindowID?
    let isCustomArea: Bool
    var isChatRegion = false
}

/// Highlights the public window under the pointer across all attached displays.
/// Capture selection rectangles use global Quartz top-down coordinates.
@MainActor
final class ScrollCaptureScopePicker: NSObject {
    private struct HoverTarget {
        let displayID: CGDirectDisplayID
        let screenRect: CGRect
        let windowRect: CGRect?
        let pageRect: CGRect?
        let isChatRegion: Bool
        let application: NSRunningApplication?
        let windowID: CGWindowID?

        var defaultRect: CGRect { (pageRect ?? windowRect ?? screenRect).intersection(screenRect).integral }
    }

    private var windows: [ScopeOverlayWindow] = []
    private var views: [CGDirectDisplayID: ScopeOverlayView] = [:]
    private var screensByDisplay: [CGDirectDisplayID: NSScreen] = [:]
    private var eventMonitors: [Any] = []
    private var activeTarget: HoverTarget?
    private var activePointer: CGPoint?
    private var customRect: CGRect?
    private var dragStart: CGPoint?
    private var dragTarget: HoverTarget?
    private var lastResolvedPoint: CGPoint?
    private var isDragging = false
    private var mouseDownCount = 0
    private var mouseUpCount = 0
    // Keep the raw value so left/right device-specific modifier bits remain
    // visible even when their shared device-independent flag is already set.
    private var rawModifierFlags = NSEvent.modifierFlags.rawValue
    private var newlyPressedModifierPending = false
    private var resolveRegion: ((NSRunningApplication, CGPoint, CGRect) -> (rect: CGRect, isChat: Bool)?)?
    private var onCapture: ((ScrollCaptureScopeSelection) -> Void)?
    private var onCancel: (() -> Void)?
    private var ownerPID = ProcessInfo.processInfo.processIdentifier

    var status: [String: Any] {
        let rect = customRect ?? activeTarget?.defaultRect ?? .zero
        let hitWindow = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return ["overlayCount": windows.count,
                "chatRegion": AutoScrollTarget.chatRegionDiagnostic,
                "applicationActive": NSApp.isActive,
                "hasKeyOverlay": windows.contains(where: { $0.isKeyWindow }),
                "mouseHitOverlay": windows.contains(where: { $0.windowNumber == hitWindow }),
                "mouseDownCount": mouseDownCount,
                "mouseUpCount": mouseUpCount,
                "displayID": activeTarget?.displayID ?? 0,
                "windowID": activeTarget?.windowID ?? 0,
                "applicationIdentifier": activeTarget?.application?.bundleIdentifier ?? "",
                "isChatRegion": activeTarget?.isChatRegion ?? false,
                "rect": ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]]
    }

    func present(scrolling: Bool,
                 resolveRegion: ((NSRunningApplication, CGPoint, CGRect) -> (rect: CGRect, isChat: Bool)?)? = nil,
                 onCapture: @escaping (ScrollCaptureScopeSelection) -> Void,
                 onCancel: @escaping () -> Void) {
        close()
        self.resolveRegion = resolveRegion
        self.onCapture = onCapture
        self.onCancel = onCancel
        ownerPID = ProcessInfo.processInfo.processIdentifier
        mouseDownCount = 0
        mouseUpCount = 0
        rawModifierFlags = NSEvent.modifierFlags.rawValue
        newlyPressedModifierPending = false
        installCancellationMonitors()

        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = number.uint32Value
            screensByDisplay[displayID] = screen
            let window = ScopeOverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = false
            window.isMovable = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.title = "Select scrolling area"
            window.onEscape = { [weak self] in self?.cancel() }
            window.onModifierFlagsChanged = { [weak self] event in
                _ = self?.handleModifierFlagsChanged(event)
            }

            let view = ScopeOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onHover = { [weak self] in self?.updateHover() }
            view.onMouseDown = { [weak self] point in
                guard let self else { return }
                self.mouseDownCount += 1
                self.beginSelection(at: point)
            }
            view.onMouseDragged = { [weak self] point in self?.dragSelection(to: point) }
            view.onMouseUp = { [weak self] point in
                guard let self else { return }
                self.mouseUpCount += 1
                self.endSelection(at: point)
            }
            view.scopeRect = { [weak self] in self?.displayHighlight(for: displayID) }
            view.dimAmount = { [weak self] in self?.dimAmount(for: displayID) ?? 0.15 }
            window.contentView = view
            window.initialFirstResponder = view
            window.makeFirstResponder(view)
            views[displayID] = view
            windows.append(window)
        }

        guard !windows.isEmpty else {
            let callback = self.onCancel
            close()
            callback?()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        if let first = windows.first { first.makeKeyAndOrderFront(nil) }
        updateHover()
    }

    func close() {
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
        let oldWindows = windows
        windows.removeAll()
        views.removeAll()
        screensByDisplay.removeAll()
        activeTarget = nil
        activePointer = nil
        customRect = nil
        dragStart = nil
        dragTarget = nil
        lastResolvedPoint = nil
        isDragging = false
        onCapture = nil
        onCancel = nil
        resolveRegion = nil
        oldWindows.forEach { $0.orderOut(nil); $0.close() }
    }

    /// Selects the current hover target for callers that trigger capture semantically.
    @discardableResult
    func confirm(scopeName: String) -> Bool {
        updateHover()
        guard let target = activeTarget, let pointer = activePointer else { return false }
        let selection: ScrollCaptureScopeSelection
        switch scopeName {
        case "page":
            guard let application = target.application else { return false }
            let rect = target.pageRect ?? target.windowRect
            guard let rect else { return false }
            let contentPoint = target.isChatRegion ? CaptureChatRegion.scrollPoint(in: rect) ?? CGPoint(x: rect.midX, y: rect.midY)
                : rect.contains(pointer) ? pointer : CGPoint(x: rect.midX, y: rect.midY)
            selection = ScrollCaptureScopeSelection(rect: rect, selectionPoint: contentPoint,
                                                    windowBounds: target.windowRect, application: application,
                                                    windowID: target.windowID, isCustomArea: false, isChatRegion: target.isChatRegion)
        case "window":
            guard let rect = target.windowRect, let application = target.application else { return false }
            selection = ScrollCaptureScopeSelection(rect: rect, selectionPoint: pointer,
                                                    windowBounds: rect, application: application,
                                                    windowID: target.windowID, isCustomArea: false)
        case "screen":
            selection = ScrollCaptureScopeSelection(rect: target.screenRect, selectionPoint: pointer,
                                                    windowBounds: nil, application: nil,
                                                    windowID: nil, isCustomArea: false)
        default:
            return false
        }
        return finish(selection)
    }

    private func updateHover() {
        guard let point = Self.currentQuartzPointer() else { return }
        updateHover(at: point)
    }

    private func updateHover(at point: CGPoint, forceResolve: Bool = false) {
        guard !isDragging, let screen = screen(at: point) else { return }
        activePointer = point
        let screenRect = Self.quartzBounds(of: screen.screen)
        var next: HoverTarget
        if let window = window(at: point) {
            let sameWindow = activeTarget?.windowID == window.id && activeTarget?.application?.processIdentifier == window.application.processIdentifier && activeTarget?.windowRect == window.rect && activeTarget?.displayID == screen.displayID
            let pageRect: CGRect?
            let isChatRegion: Bool
            if let resolver = resolveRegion {
                // Resolve only as the pointer moves across targets or meaningfully
                // within one, avoiding an AX query for every mouse-moved event.
                let shouldResolve = forceResolve || !sameWindow || lastResolvedPoint.map {
                    hypot(point.x - $0.x, point.y - $0.y) > 18
                } ?? true
                if shouldResolve {
                    let resolved = resolver(window.application, point, window.rect)
                    pageRect = resolved.flatMap { Self.valid($0.rect, within: window.rect) }
                    isChatRegion = pageRect != nil && resolved?.isChat == true
                    lastResolvedPoint = point
                } else if sameWindow {
                    pageRect = activeTarget?.pageRect
                    isChatRegion = activeTarget?.isChatRegion ?? false
                } else {
                    pageRect = nil
                    isChatRegion = false
                }
            } else {
                pageRect = nil
                isChatRegion = false
            }
            next = HoverTarget(displayID: screen.displayID, screenRect: screenRect,
                               windowRect: window.rect, pageRect: pageRect, isChatRegion: isChatRegion,
                               application: window.application, windowID: window.id)
        } else {
            next = HoverTarget(displayID: screen.displayID, screenRect: screenRect,
                               windowRect: nil, pageRect: nil, isChatRegion: false, application: nil, windowID: nil)
        }
        activeTarget = next
        refreshViews()
    }

    private func screen(at point: CGPoint) -> (displayID: CGDirectDisplayID, screen: NSScreen)? {
        for (displayID, screen) in screensByDisplay where Self.quartzBounds(of: screen).contains(point) {
            return (displayID, screen)
        }
        return nil
    }

    private func window(at point: CGPoint) -> (id: CGWindowID, rect: CGRect, application: NSRunningApplication)? {
        guard let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in entries {
            guard let owner = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != ownerPID,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.05,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsValue = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsValue as CFDictionary), rect.contains(point),
                  let application = NSRunningApplication(processIdentifier: owner) else { continue }
            return (id, rect, application)
        }
        return nil
    }

    private func beginSelection(at point: CGPoint) {
        // Hover can still describe a screen fallback or an overlapping window
        // when the click arrives. Resolve the event's actual point before
        // freezing the target; mouse-up must not retarget the selection.
        updateHover(at: point, forceResolve: true)
        dragStart = point
        dragTarget = activeTarget
        customRect = nil
        isDragging = false
        refreshViews()
    }

    private func dragSelection(to point: CGPoint) {
        guard let start = dragStart else { return }
        if hypot(point.x - start.x, point.y - start.y) >= 4 { isDragging = true }
        guard isDragging else { return }
        customRect = Self.bounded(CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                         width: abs(point.x - start.x), height: abs(point.y - start.y)))
        refreshViews()
    }

    private func endSelection(at point: CGPoint) {
        guard let start = dragStart else { return }
        // Mouse-up can arrive at a displaced point even if AppKit did not send
        // an intermediate dragged event. Preserve the drag-to-select path.
        dragSelection(to: point)
        if isDragging {
            guard let rect = customRect, rect.width >= 80, rect.height >= 100 else {
                dragStart = nil; dragTarget = nil; customRect = nil; isDragging = false
                updateHover()
                return
            }
            let owner = dragTarget ?? activeTarget
            let selection = ScrollCaptureScopeSelection(rect: rect, selectionPoint: start,
                                                        windowBounds: owner?.windowRect, application: owner?.application,
                                                        windowID: owner?.windowID, isCustomArea: true)
            _ = finish(selection)
        } else {
            guard let target = dragTarget else { return }
            let rect = target.defaultRect
            let contentPoint = target.isChatRegion ? CaptureChatRegion.scrollPoint(in: rect) ?? CGPoint(x: rect.midX, y: rect.midY)
                : rect.contains(start) ? start : CGPoint(x: rect.midX, y: rect.midY)
            let selection = ScrollCaptureScopeSelection(rect: rect, selectionPoint: contentPoint,
                                                        windowBounds: target.windowRect,
                                                        application: target.application,
                                                        windowID: target.windowID, isCustomArea: false, isChatRegion: target.isChatRegion)
            _ = finish(selection)
        }
    }

    private func finish(_ selection: ScrollCaptureScopeSelection) -> Bool {
        guard let callback = onCapture, Self.isFinite(selection.rect), !selection.rect.isEmpty else { return false }
        close()
        callback(selection)
        return true
    }

    private func cancel() {
        guard let callback = onCancel else { close(); return }
        close()
        callback()
    }

    @discardableResult
    private func handleModifierFlagsChanged(_ event: NSEvent) -> Bool {
        let nextRawFlags = event.modifierFlags.rawValue
        let pressedFlags = nextRawFlags & ~rawModifierFlags
        rawModifierFlags = nextRawFlags
        if pressedFlags != 0 { newlyPressedModifierPending = true }
        let momentaryMask = NSEvent.ModifierFlags([.shift, .control, .option, .command, .function]).rawValue
        let momentaryModifiersHeld = (nextRawFlags & momentaryMask) != 0
        guard newlyPressedModifierPending, !momentaryModifiersHeld else { return false }
        newlyPressedModifierPending = false
        cancel()
        return true
    }

    private func installCancellationMonitors() {
        let types: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .rightMouseDown, .otherMouseDown, .scrollWheel]
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] event in
            guard let self, self.onCancel != nil else { return event }
            if event.type == .flagsChanged {
                return self.handleModifierFlagsChanged(event) ? nil : event
            }
            self.cancel()
            return nil
        }) else { return }
        eventMonitors.append(monitor)
    }

    private func displayHighlight(for displayID: CGDirectDisplayID) -> CGRect? {
        if let customRect { return customRect }
        guard let activeTarget, activeTarget.displayID == displayID else { return nil }
        return activeTarget.defaultRect
    }

    private func dimAmount(for displayID: CGDirectDisplayID) -> CGFloat {
        guard let activeTarget else { return 0.15 }
        return activeTarget.displayID == displayID ? 0.15 : 0.15
    }

    private func refreshViews() { views.values.forEach { $0.needsDisplay = true } }

    private static func currentQuartzPointer() -> CGPoint? {
        guard let point = CGEvent(source: nil)?.location, point.x.isFinite, point.y.isFinite else { return nil }
        return point
    }

    private static func quartzBounds(of screen: NSScreen) -> CGRect {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return .zero }
        return CGDisplayBounds(number.uint32Value)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    private static func bounded(_ rect: CGRect) -> CGRect {
        guard isFinite(rect) else { return .zero }
        return rect.standardized.integral
    }

    private static func valid(_ rect: CGRect, within bounds: CGRect) -> CGRect? {
        guard isFinite(rect), isFinite(bounds) else { return nil }
        let clipped = rect.standardized.intersection(bounds).integral
        guard !clipped.isNull, clipped.width >= 80, clipped.height >= 100 else { return nil }
        return clipped
    }
}

@MainActor
private final class ScopeOverlayWindow: NSWindow {
    var onEscape: () -> Void = {}
    var onModifierFlagsChanged: (NSEvent) -> Void = { _ in }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape() }
    override func keyDown(with event: NSEvent) {
        onEscape()
    }
    override func flagsChanged(with event: NSEvent) { onModifierFlagsChanged(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onEscape(); return true }
}

@MainActor
private final class ScopeOverlayView: NSView {
    var scopeRect: () -> CGRect? = { nil }
    var dimAmount: () -> CGFloat = { 0.15 }
    var onHover: () -> Void = {}
    var onMouseDown: (CGPoint) -> Void = { _ in }
    var onMouseDragged: (CGPoint) -> Void = { _ in }
    var onMouseUp: (CGPoint) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover() }
    override func mouseMoved(with event: NSEvent) { onHover() }
    override func mouseDown(with event: NSEvent) { onMouseDown(Self.globalPoint(event, in: self)) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged(Self.globalPoint(event, in: self)) }
    override func mouseUp(with event: NSEvent) { onMouseUp(Self.globalPoint(event, in: self)) }
    override func keyDown(with event: NSEvent) { (window as? ScopeOverlayWindow)?.onEscape() }
    override func flagsChanged(with event: NSEvent) { (window as? ScopeOverlayWindow)?.onModifierFlagsChanged(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        (window as? ScopeOverlayWindow)?.onEscape()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let localBounds = bounds
        guard let screen = window?.screen,
              let targetGlobal = scopeRect(),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            NSColor.black.withAlphaComponent(dimAmount()).setFill()
            localBounds.fill()
            return
        }
        let quartzBounds = CGDisplayBounds(number.uint32Value)
        let targetOnDisplay = targetGlobal.intersection(quartzBounds)
        let localTarget = CGRect(x: targetOnDisplay.minX - quartzBounds.minX,
                                 y: quartzBounds.maxY - targetOnDisplay.maxY,
                                 width: targetOnDisplay.width, height: targetOnDisplay.height)
        NSColor.black.withAlphaComponent(dimAmount()).setFill()
        let shade = NSBezierPath(rect: localBounds)
        if !targetOnDisplay.isNull, !targetOnDisplay.isEmpty {
            shade.append(NSBezierPath(rect: localTarget))
            shade.windingRule = .evenOdd
        }
        shade.fill()
        guard !targetOnDisplay.isNull, !targetOnDisplay.isEmpty else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(rect: localTarget.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 2
        outline.stroke()
    }

    private static func globalPoint(_ event: NSEvent, in view: NSView) -> CGPoint {
        guard let window = view.window else { return .zero }
        let appKitPoint = window.convertPoint(toScreen: event.locationInWindow)
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) ?? window.screen
        guard let targetScreen,
              let number = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return .zero }
        let displayBounds = CGDisplayBounds(number.uint32Value)
        let localX = appKitPoint.x - targetScreen.frame.minX
        let localY = appKitPoint.y - targetScreen.frame.minY
        return CGPoint(x: displayBounds.minX + localX, y: displayBounds.maxY - localY)
    }
}
