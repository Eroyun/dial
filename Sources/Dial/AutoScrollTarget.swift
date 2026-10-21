import AppKit
import ApplicationServices
import CoreGraphics

/// A bounded, accessibility-derived content region in the application that owned focus
/// before Dial began capture. All coordinates accepted and returned here are Quartz
/// global / display-local top-down points, as expected by ScreenCaptureKit.
@MainActor
final class AutoScrollTarget {
    enum Failure: LocalizedError {
        case accessibilityUnavailable, applicationChanged, windowChanged
        case noScrollableContent, displayUnavailable, contentChanged, eventUnavailable

        var errorDescription: String? {
            switch self {
            case .accessibilityUnavailable: "Enable Accessibility for Dial to scroll this page automatically."
            case .applicationChanged: "The original application is no longer in front."
            case .windowChanged: "The original window changed during capture."
            case .noScrollableContent: "No scrollable page content was found at the pointer."
            case .displayUnavailable: "The page content is not on an active display."
            case .contentChanged: "The original scrollable content changed during capture."
            case .eventUnavailable: "The scroll event could not be created."
            }
        }
    }

    /// Entry diagnostics contain only stages, API result codes and geometry.
    /// They intentionally exclude AX titles, URLs and captured content.
    struct EntryDiagnostic {
        enum Stage: String {
            case accessibility, application, focusedWindow, focusedBounds
            case expectedBounds, expectedCGWindow, ready
            case axWindowCount, axWindowValues, axWindowFrame, axWindowMatch
            case activationApplication, activationBudget, activationRaise
            case pointer, content, contentAncestry, display, viewport, documentIdentity, resolveBudget
        }
        let stage: Stage
        let axError: Int32?
        let expectedBounds: CGRect?
        let actualBounds: CGRect?
        let axWindowCount: Int?
        let axWindowMatchCount: Int?
        let cgWindowMatchCount: Int?
        let expectedWindowID: CGWindowID?
        let actualWindowID: CGWindowID?

        var fields: [String: String] {
            var fields = ["stage": stage.rawValue]
            if let axError { fields["ax_error"] = String(axError) }
            if let axWindowCount { fields["ax_window_count"] = String(axWindowCount) }
            if let axWindowMatchCount { fields["ax_window_match_count"] = String(axWindowMatchCount) }
            if let cgWindowMatchCount { fields["cg_window_match_count"] = String(cgWindowMatchCount) }
            if let expectedWindowID { fields["expected_window_id"] = String(expectedWindowID) }
            if let actualWindowID { fields["actual_window_id"] = String(actualWindowID) }
            for (name, rect) in [("expected_bounds", expectedBounds), ("actual_bounds", actualBounds)] {
                if let rect { fields[name] = "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)" }
            }
            return fields
        }
    }

    private(set) static var lastEntryDiagnostic: EntryDiagnostic?
    private(set) static var chatRegionDiagnostic: [String: String] = [:]
    static func resetEntryDiagnostic() { lastEntryDiagnostic = nil }

    private static func recordEntry(_ stage: EntryDiagnostic.Stage, budget: Budget? = nil,
                                    axError: Int32? = nil,
                                    expectedBounds: CGRect? = nil, actualBounds: CGRect? = nil,
                                    axWindowCount: Int? = nil,
                                    axMatches: Int? = nil, cgMatches: Int? = nil,
                                    expectedWindowID: CGWindowID? = nil, actualWindowID: CGWindowID? = nil) {
        lastEntryDiagnostic = EntryDiagnostic(stage: stage, axError: axError ?? budget?.errorCode,
            expectedBounds: expectedBounds, actualBounds: actualBounds,
            axWindowCount: axWindowCount, axWindowMatchCount: axMatches, cgWindowMatchCount: cgMatches,
            expectedWindowID: expectedWindowID, actualWindowID: actualWindowID)
    }

    let pid: pid_t
    let displayID: CGDirectDisplayID
    private(set) var sourceRect: CGRect
    var contentRect: CGRect { visibleContentRect }
    var captureWindowRect: CGRect { windowRect }
    let originalScrollFraction: Double?
    private(set) var lastScrollRoute = ""
    /// Requested magnitude sent by the previous route, not measured page movement.
    private(set) var lastScrollMagnitude = 0
    private(set) var lastValidationIssue = ""
    private(set) var lastScrollPauseReason = ""
    private(set) var lastSystemHitOwnerPID: pid_t?
    /// Raw destination metadata for the last marked wheel; this is diagnostic
    /// evidence only and does not change the gate or prove document movement.
    private(set) var lastScrollDestinationDiagnostic: [String: String] = [:]

    private let window: AXUIElement
    private let content: AXUIElement
    private let identitySource: AXUIElement
    private let contentRole: String
    let windowRect: CGRect
    let visibleContentRect: CGRect
    /// Public WindowServer identity, resolved only when PID/layer/bounds are unique.
    let targetWindowID: CGWindowID?
    private(set) var scrollPoint: CGPoint
    private let documentIdentity: DocumentIdentity
    /// Development proof is limited to explicit public fixtures. Never expose
    /// the current document URL or title through status or diagnostics.
    var isPublicFrameProofFixture: Bool {
        guard case .url(let url) = documentIdentity else { return false }
        return ["https://en.wikipedia.org/wiki/Cairo_(graphics)",
                "https://en.wikipedia.org/wiki/Screenshot"].contains(url)
    }
    private let initialScrollState: ScrollbarState?
    private var scrollingStarted = false
    private var sessionWheelGate: CaptureWheelGate?

    private enum DocumentIdentity: Equatable {
        case url(String)
        case windowTitle(String)
    }

    private struct ScrollbarState {
        let value: Double
        let minimum: Double
        let maximum: Double

        var fraction: Double { (value - minimum) / (maximum - minimum) }
    }

    private final class Budget {
        private let deadline: UInt64
        private var consecutiveUnavailable = 0
        private var lastError: AXError = .success

        init(seconds: Double) {
            deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        }

        var available: Bool {
            consecutiveUnavailable < 2 && DispatchTime.now().uptimeNanoseconds < deadline
        }

        var isBusy: Bool { !available || lastError == .cannotComplete }
        var errorCode: Int32 { lastError.rawValue }
        var messagingTimeout: Float {
            let now = DispatchTime.now().uptimeNanoseconds
            let remaining = now < deadline ? Double(deadline - now) / 1_000_000_000 : 0
            return Float(min(0.08, max(0.001, remaining)))
        }

        func record(_ result: AXError) {
            lastError = result
            consecutiveUnavailable = result == .cannotComplete ? consecutiveUnavailable + 1 : 0
        }
    }

    // AX calls are synchronous on the main actor. The total budget below is the
    // primary bound; each individual call also has this short timeout.
    private static let axQueryTimeout: Float = 0.08

    private init(pid: pid_t, displayID: CGDirectDisplayID, sourceRect: CGRect,
                 window: AXUIElement, content: AXUIElement, identitySource: AXUIElement,
                 contentRole: String, windowRect: CGRect,
                 visibleContentRect: CGRect, scrollPoint: CGPoint,
                 documentIdentity: DocumentIdentity, initialScrollState: ScrollbarState?) {
        self.pid = pid
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.window = window
        self.content = content
        self.identitySource = identitySource
        self.contentRole = contentRole
        self.windowRect = windowRect
        self.visibleContentRect = visibleContentRect
        self.scrollPoint = scrollPoint
        self.targetWindowID = Self.uniqueWindowID(pid: pid, bounds: windowRect)
        self.documentIdentity = documentIdentity
        self.initialScrollState = initialScrollState
        self.originalScrollFraction = initialScrollState?.fraction
    }

    /// Resolve while the original application is still frontmost. `pointer` is a
    /// Quartz global top-down position; omitted means the current mouse position.
    static func resolve(application: NSRunningApplication, pointer: CGPoint? = nil,
                        expectedWindowBounds: CGRect? = nil,
                        expectedWindowID: CGWindowID? = nil, chatBounds: CGRect? = nil) throws -> AutoScrollTarget {
        resetEntryDiagnostic()
        let budget = Budget(seconds: 2)
        recordEntry(.accessibility)
        guard AXIsProcessTrusted() else { throw Failure.accessibilityUnavailable }
        let pid = application.processIdentifier
        recordEntry(.application)
        guard pid > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            throw Failure.applicationChanged
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axQueryTimeout)
        guard let window = element(app, kAXFocusedWindowAttribute, budget: budget) else {
            recordEntry(.focusedWindow, budget: budget)
            throw Failure.windowChanged
        }
        AXUIElementSetMessagingTimeout(window, axQueryTimeout)
        guard let windowRect = frame(window, budget: budget), windowRect.width > 0, windowRect.height > 0 else {
            recordEntry(.focusedBounds, budget: budget)
            throw Failure.windowChanged
        }
        if let expectedWindowBounds, !close(windowRect, to: expectedWindowBounds) {
            recordEntry(.expectedBounds, budget: budget,
                        expectedBounds: expectedWindowBounds, actualBounds: windowRect)
            throw Failure.windowChanged
        }
        if let expectedWindowID {
            let matches = matchingCGWindowIDs(pid: pid, bounds: windowRect)
            let actualID = matches?.count == 1 ? matches?.first : nil
            if actualID != expectedWindowID {
                recordEntry(.expectedCGWindow, budget: budget,
                            expectedBounds: expectedWindowBounds, actualBounds: windowRect,
                            cgMatches: matches?.count, expectedWindowID: expectedWindowID,
                            actualWindowID: actualID)
                throw Failure.windowChanged
            }
        }
        var point = pointer ?? CGEvent(source: nil)?.location ?? .zero
        recordEntry(.pointer, budget: budget)
        guard point.x.isFinite, point.y.isFinite else { throw Failure.noScrollableContent }

        if let chatBounds {
            guard windowRect.contains(chatBounds),
                  let tested = CaptureChatRegion.scrollPoints(in: chatBounds).first(where: {
                      usableChatPoint($0, app: app, window: window, chatBounds: chatBounds, budget: budget)
                  }) else {
                recordEntry(.contentAncestry, budget: budget)
                throw Failure.noScrollableContent
            }
            point = tested
        }

        // Prefer the innermost scroll region under the pointer. Toolbar or desktop
        // pointer positions fall back to a bounded focused-window search.
        let selected = windowRect.contains(point)
            ? hitContent(in: app, window: window, windowRect: windowRect, at: point, budget: budget)
            : nil
        let resolved = selected ?? largestWindowContent(in: window, windowRect: windowRect, budget: budget)
        guard let (content, role, contentRect, identitySource) = resolved else {
            recordEntry(.content, budget: budget)
            throw Failure.noScrollableContent
        }
        guard isDescendant(content, of: window, budget: budget) else {
            recordEntry(.contentAncestry, budget: budget)
            throw Failure.noScrollableContent
        }
        let bounded = contentRect.intersection(windowRect)
        guard !bounded.isNull, let (displayID, displayBounds) = display(overlapping: bounded, pointer: point) else {
            recordEntry(.display, budget: budget)
            throw Failure.displayUnavailable
        }
        let visible = bounded.intersection(displayBounds).integral
        guard visible.width >= 80, visible.height >= 100,
              visible.width * visible.height <= 8_000_000 else {
            recordEntry(.viewport, budget: budget, actualBounds: visible)
            throw Failure.noScrollableContent
        }
        let sourceRect = visible.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        // Stay inside the selected region, away from scrollbars and edge controls.
        let inset = visible.insetBy(dx: min(24, visible.width / 5), dy: min(24, visible.height / 5))
        let scrollPoint: CGPoint
        switch selected {
        case _ where chatBounds != nil:
            scrollPoint = point
        case .none:
            scrollPoint = CGPoint(x: inset.midX, y: inset.midY)
        case .some:
            scrollPoint = CGPoint(x: min(max(point.x, inset.minX), inset.maxX),
                                  y: min(max(point.y, inset.minY), inset.maxY))
        }
        guard let identity = documentIdentity(content: identitySource, window: window, budget: budget) else {
            recordEntry(.documentIdentity, budget: budget)
            throw Failure.noScrollableContent
        }
        guard budget.available else {
            recordEntry(.resolveBudget, budget: budget)
            throw Failure.noScrollableContent
        }
        recordEntry(.ready, budget: budget, expectedBounds: expectedWindowBounds,
                    actualBounds: windowRect, expectedWindowID: expectedWindowID)
        return AutoScrollTarget(pid: pid, displayID: displayID, sourceRect: sourceRect,
                                window: window, content: content, identitySource: identitySource,
                                contentRole: role, windowRect: windowRect,
                                visibleContentRect: visible, scrollPoint: scrollPoint,
                                documentIdentity: identity,
                                initialScrollState: scrollbarState(content, budget: budget))
    }

    /// Hover metadata only. App-specific hit testing excludes Dial's overlay;
    /// the matched AX window need not be focused and no input is issued here.
    static func previewContentRect(application: NSRunningApplication,
                                   windowBounds: CGRect, pointer: CGPoint) -> (rect: CGRect, isChat: Bool)? {
        chatRegionDiagnostic = [:]
        guard AXIsProcessTrusted(), application.processIdentifier > 0,
              pointer.x.isFinite, pointer.y.isFinite, windowBounds.contains(pointer) else { return nil }
        let budget = Budget(seconds: 0.25)
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, axQueryTimeout)
        guard let window = matchingWindow(in: app, bounds: windowBounds, budget: budget) else { return nil }
        if let chat = chatContentRect(application: application, app: app, window: window,
                                      windowRect: windowBounds, pointer: pointer, budget: budget) {
            return (chat, true)
        }
        let selected = hitContent(in: app, window: window, windowRect: windowBounds,
                                  at: pointer, budget: budget)
            ?? largestWindowContent(in: window, windowRect: windowBounds, budget: budget)
        guard let selected, budget.available else { return nil }
        let visible = selected.2.intersection(windowBounds)
        guard !visible.isNull,
              visible.width >= 80, visible.height >= 100,
              visible.width * visible.height <= 8_000_000 else { return nil }
        return (visible, false)
    }

    /// Bring only the explicitly requested running app forward. Accessory apps
    /// without a visible window cannot reliably own activation first, so use
    /// the advertised public application-level AX attribute when available.
    static func activateApplication(_ application: NSRunningApplication) throws {
        guard application.processIdentifier > 0, !application.isTerminated else {
            recordEntry(.activationApplication)
            throw Failure.applicationChanged
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier { return }
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            AXUIElementSetMessagingTimeout(app, axQueryTimeout)
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(app, kAXFrontmostAttribute as CFString, &settable) == .success,
               settable.boolValue {
                let result = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                guard result == .success else {
                    recordEntry(.activationApplication, axError: result.rawValue)
                    throw Failure.applicationChanged
                }
                return
            }
        }
        NSApp.yieldActivation(to: application)
        guard application.activate(options: []) else {
            recordEntry(.activationApplication)
            throw Failure.applicationChanged
        }
    }

    /// Call only after the user clicks a window in the picker. This raises the
    /// exact matched window; the caller then waits for focus and resolves again.
    static func activateWindow(application: NSRunningApplication, bounds: CGRect) throws {
        resetEntryDiagnostic()
        recordEntry(.accessibility, expectedBounds: bounds)
        guard AXIsProcessTrusted() else { throw Failure.accessibilityUnavailable }
        recordEntry(.application, expectedBounds: bounds)
        guard application.processIdentifier > 0, !application.isTerminated else {
            throw Failure.applicationChanged
        }
        let budget = Budget(seconds: 0.6)
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, axQueryTimeout)
        guard let window = matchingWindow(in: app, bounds: bounds, budget: budget) else {
            throw Failure.windowChanged
        }
        guard budget.available else {
            recordEntry(.activationBudget, budget: budget, expectedBounds: bounds)
            throw Failure.windowChanged
        }
        try activateApplication(application)
        AXUIElementSetMessagingTimeout(window, axQueryTimeout)
        guard budget.available else {
            recordEntry(.activationBudget, budget: budget, expectedBounds: bounds)
            throw Failure.windowChanged
        }
        let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        budget.record(result)
        guard result == .success else {
            recordEntry(.activationRaise, budget: budget, expectedBounds: bounds)
            throw Failure.windowChanged
        }
        resetEntryDiagnostic()
    }

    /// Called inside the coordinator's existing one-second focus wait. A poll
    /// never raises a different window or accepts ambiguous public CG metadata.
    static func focusedWindowIsReady(application: NSRunningApplication,
                                     expectedWindowBounds: CGRect,
                                     expectedWindowID: CGWindowID?,
                                     remainingSeconds: Double) -> Bool {
        guard remainingSeconds.isFinite, remainingSeconds > 0 else {
            // Preserve the last specific guard for a coordinator timeout.
            if lastEntryDiagnostic == nil {
                recordEntry(.activationBudget, expectedBounds: expectedWindowBounds,
                            expectedWindowID: expectedWindowID)
            }
            return false
        }
        resetEntryDiagnostic()
        let budget = Budget(seconds: min(remainingSeconds, 0.16))
        recordEntry(.accessibility)
        guard AXIsProcessTrusted() else { return false }
        let pid = application.processIdentifier
        recordEntry(.application)
        guard pid > 0, !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(min(Double(axQueryTimeout), remainingSeconds)))
        guard let window = element(app, kAXFocusedWindowAttribute, budget: budget) else {
            recordEntry(.focusedWindow, budget: budget)
            return false
        }
        guard let bounds = frame(window, budget: budget), bounds.width > 0, bounds.height > 0 else {
            recordEntry(.focusedBounds, budget: budget)
            return false
        }
        guard close(bounds, to: expectedWindowBounds) else {
            recordEntry(.expectedBounds, budget: budget,
                        expectedBounds: expectedWindowBounds, actualBounds: bounds)
            return false
        }
        let matches = matchingCGWindowIDs(pid: pid, bounds: bounds)
        let actualID = matches?.count == 1 ? matches?.first : nil
        guard let expectedWindowID, actualID == expectedWindowID else {
            recordEntry(.expectedCGWindow, budget: budget,
                        expectedBounds: expectedWindowBounds, actualBounds: bounds,
                        cgMatches: matches?.count, expectedWindowID: expectedWindowID,
                        actualWindowID: actualID)
            return false
        }
        guard budget.available else {
            recordEntry(.activationBudget, budget: budget)
            return false
        }
        recordEntry(.ready, budget: budget,
                    expectedBounds: expectedWindowBounds, actualBounds: bounds,
                    cgMatches: matches?.count, expectedWindowID: expectedWindowID,
                    actualWindowID: actualID)
        return true
    }

    /// Enumerate the application's AX windows within a bounded query. Never use
    /// focus as a substitute for an absent or ambiguous hovered-window match.
    private static func matchingWindow(in app: AXUIElement, bounds: CGRect,
                                       budget: Budget) -> AXUIElement? {
        guard bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0, budget.available else {
            recordEntry(.axWindowMatch, budget: budget, expectedBounds: bounds)
            return nil
        }
        var count: CFIndex = 0
        AXUIElementSetMessagingTimeout(app, budget.messagingTimeout)
        let counted = AXUIElementGetAttributeValueCount(app, kAXWindowsAttribute as CFString, &count)
        budget.record(counted)
        guard counted == .success, (1...64).contains(count), budget.available else {
            recordEntry(.axWindowCount, budget: budget, expectedBounds: bounds, axWindowCount: count)
            return nil
        }
        var values: CFArray?
        AXUIElementSetMessagingTimeout(app, budget.messagingTimeout)
        let queried = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString,
                                                     0, count, &values)
        budget.record(queried)
        guard queried == .success, let values, CFArrayGetCount(values) == count,
              budget.available else {
            recordEntry(.axWindowValues, budget: budget, expectedBounds: bounds, axWindowCount: count)
            return nil
        }
        var matches: [AXUIElement] = []
        for value in values as NSArray {
            guard budget.available else {
                recordEntry(.axWindowFrame, budget: budget, expectedBounds: bounds,
                            axWindowCount: count, axMatches: matches.count)
                return nil
            }
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { continue }
            let window = cfValue as! AXUIElement
            guard let windowFrame = frame(window, budget: budget) else {
                recordEntry(.axWindowFrame, budget: budget, expectedBounds: bounds,
                            axWindowCount: count, axMatches: matches.count)
                return nil
            }
            if close(windowFrame, to: bounds) { matches.append(window) }
        }
        guard budget.available, matches.count == 1 else {
            recordEntry(.axWindowMatch, budget: budget, expectedBounds: bounds,
                        axWindowCount: count, axMatches: matches.count)
            return nil
        }
        return matches[0]
    }

    /// Check before every capture and every synthetic scroll. A changed window,
    /// content element, focus owner, or geometry ends this session.
    func isCurrent() -> Bool {
        lastValidationIssue = ""
        let budget = Budget(seconds: 0.6)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return validationFailed("foreground_changed")
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.axQueryTimeout)
        guard let focused = Self.element(app, kAXFocusedWindowAttribute, budget: budget) else {
            return validationFailed(budget.isBusy ? "AX_busy" : "focused_window_changed")
        }
        guard CFEqual(focused, window) else { return validationFailed("focused_window_changed") }
        guard Self.string(content, kAXRoleAttribute, budget: budget) == contentRole else {
            return validationFailed(budget.isBusy ? "AX_busy" : "document_detached")
        }
        guard Self.isDescendant(identitySource, of: content, budget: budget) else {
            return validationFailed(budget.isBusy ? "AX_busy" : "document_detached")
        }
        guard Self.documentIdentity(content: identitySource, window: focused,
                                    budget: budget) == documentIdentity else {
            return validationFailed(budget.isBusy ? "AX_busy" : "document_changed")
        }
        guard let focusedRect = Self.frame(focused, budget: budget) else {
            return validationFailed(budget.isBusy ? "AX_busy" : "window_geometry_changed")
        }
        guard Self.close(focusedRect, to: windowRect) else {
            return validationFailed("window_geometry_changed")
        }
        if let targetWindowID,
           Self.uniqueWindowID(pid: pid, bounds: focusedRect) != targetWindowID {
            return validationFailed("window_identity_changed")
        }
        guard let contentFrame = Self.frame(content, budget: budget) else {
            return validationFailed(budget.isBusy ? "AX_busy" : "document_detached")
        }
        if contentRole == kAXScrollAreaRole {
            let visible = contentFrame.intersection(focusedRect).intersection(CGDisplayBounds(displayID))
            guard !visible.isNull, visible.contains(scrollPoint),
                  Self.close(visible, to: visibleContentRect) else {
                return validationFailed("viewport_geometry_changed")
            }
        } else {
            // AXWebArea can expose a moving full-document frame. The fixed
            // capture region must remain inside the same focused window and
            // intersect that same document; translation alone is not a change.
            guard contentFrame.intersects(visibleContentRect) else {
                return validationFailed("viewport_geometry_changed")
            }
        }
        var hit: AXUIElement?
        guard budget.available else { return validationFailed("AX_busy") }
        let result = AXUIElementCopyElementAtPosition(app, Float(scrollPoint.x), Float(scrollPoint.y), &hit)
        budget.record(result)
        guard result == .success else {
            return validationFailed("point_hit_ax_\(result.rawValue)")
        }
        guard let hit else {
            return validationFailed("point_hit_missing")
        }
        let ancestry = Self.ancestryWalk(hit, of: content, budget: budget)
        guard ancestry.containsTarget else {
            var issue = ancestry.validationIssue ?? "point_not_in_content"
            if budget.isBusy { issue += "_ax_\(budget.errorCode)" }
            return validationFailed(issue)
        }
        guard budget.available else { return validationFailed("AX_busy") }
        return true
    }

    private func validationFailed(_ issue: String) -> Bool {
        lastValidationIssue = issue
        return false
    }

    private static func close(_ a: CGRect, to b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3 &&
        abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
    }

    /// Configure the crop before starting the engine. A custom crop supplies its
    /// own content point; that destination and document identity then stay fixed.
    func configureCaptureRegion(_ globalRect: CGRect, preferredScrollPoint: CGPoint? = nil) throws {
        guard !scrollingStarted,
              globalRect.minX.isFinite, globalRect.minY.isFinite,
              globalRect.width.isFinite, globalRect.height.isFinite,
              globalRect.width > 0, globalRect.height > 0 else {
            throw Failure.noScrollableContent
        }
        let displayBounds = CGDisplayBounds(displayID)
        let clipped = globalRect.intersection(displayBounds).intersection(windowRect)
        let destination = preferredScrollPoint ?? scrollPoint
        guard !clipped.isNull, clipped.width >= 80, clipped.height >= 100,
              clipped.width * clipped.height <= 8_000_000,
              destination.x.isFinite, destination.y.isFinite,
              visibleContentRect.contains(destination), clipped.contains(destination) else {
            throw Failure.noScrollableContent
        }
        scrollPoint = destination
        sourceRect = clipped.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }

    func scrollDown(pixels: Int) throws {
        guard (1...2_000).contains(pixels) else { throw Failure.eventUnavailable }
        try scroll(pixels: -pixels)
    }
    func scrollUp(pixels: Int) throws {
        guard (1...2_000).contains(pixels) else { throw Failure.eventUnavailable }
        try scroll(pixels: pixels)
    }

    /// Seek directly toward the top only during pre-capture endpoint preparation.
    /// The event still passes through the selected-window destination gate.
    func scrollUpTowardTop(pixels: Int) throws {
        guard (1...2_000).contains(pixels) else { throw Failure.eventUnavailable }
        try seekEndpoint(towardTop: true)
    }

    /// Seek directly toward the bottom only during pre-capture endpoint preparation.
    func scrollDownTowardBottom(pixels: Int) throws {
        guard (1...2_000).contains(pixels) else { throw Failure.eventUnavailable }
        try seekEndpoint(towardTop: false)
    }

    private func seekEndpoint(towardTop: Bool) throws {
        try scroll(pixels: EndpointNavigation.seekWheelPixels(towardTop: towardTop),
                   endpointSeek: true)
    }

    private func scroll(pixels: Int, endpointSeek: Bool = false) throws {
        scrollingStarted = true
        lastScrollRoute = ""
        lastScrollMagnitude = 0
        lastScrollPauseReason = ""
        lastSystemHitOwnerPID = nil
        lastScrollDestinationDiagnostic = [:]
        guard isCurrent() else { throw Failure.contentChanged }
        let requestedPixels: Int
        if endpointSeek { requestedPixels = pixels }
        else {
            // Preserve overlap in the central half, including short custom
            // selections. The ordinary 180-point ceiling still applies below.
            let limit = EndpointNavigation.ordinaryWheelLimit(viewportHeight: sourceRect.height)
            requestedPixels = max(-limit, min(limit, pixels))
        }
        // Exact AX boundary writes are attempted by moveToBoundaryIfSupported
        // before seeking. Here an endpoint seek must use the bounded, verified
        // session wheel directly; a viewport-sized native increment could leave
        // a long document tens of thousands of pixels away after the 48-step cap.
        if !endpointSeek && scrollWithNativeScrollbar(pixels: requestedPixels) {
            lastScrollRoute = "accessibility-scrollbar"
            return
        }
        // Session delivery passes WindowServer annotation; direct PID posting
        // did not advance Chrome in the native test. An owned downstream gate
        // checks the annotated destination before this event reaches any app.
        guard isCurrent() else { throw Failure.contentChanged }
        guard let targetWindowID,
              Self.uniqueWindowID(pid: pid, bounds: windowRect) == targetWindowID else {
            throw Failure.windowChanged
        }
        if sessionWheelGate == nil {
            sessionWheelGate = CaptureWheelGate(pid: pid, windowID: targetWindowID)
        }
        guard let gate = sessionWheelGate, gate.available else {
            throw Failure.eventUnavailable
        }
        let boundedPixels = EndpointNavigation.boundedWheelPixels(requestedPixels, endpointSeek: endpointSeek)
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 1, wheel1: Int32(boundedPixels), wheel2: 0, wheel3: 0) else {
            throw Failure.eventUnavailable
        }
        event.flags = []
        event.location = scrollPoint
        event.setIntegerValueField(.eventSourceUserData, value: gate.tag)
        gate.prepare(magnitude: abs(boundedPixels))
        event.post(tap: .cgSessionEventTap)
        lastScrollRoute = "quartz-session-pending"
    }

    /// Destination acknowledgement is distinct from measured page movement.
    /// Never queue another wheel or read a frame before this delivery resolves.
    func waitForScrollDelivery() async throws {
        guard lastScrollRoute == "quartz-session-pending", let gate = sessionWheelGate else { return }
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            try Task.checkCancellation()
            let receipt = gate.receipt
            if receipt.resolved {
                lastSystemHitOwnerPID = receipt.pid
                lastScrollDestinationDiagnostic = receipt.diagnostic
                lastScrollRoute = receipt.delivered ? "quartz-session" : "quartz-session-paused"
                lastScrollMagnitude = receipt.delivered ? receipt.magnitude : 0
                lastScrollPauseReason = receipt.delivered ? "" : "event_destination_changed"
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        gate.expire()
        lastScrollRoute = "quartz-session-paused"
        lastScrollPauseReason = "event_delivery_unobserved"
        lastScrollMagnitude = 0
    }

    /// Session wheel events never move the pointer, so no restoration is needed.
    @discardableResult
    func restorePointerIfUnmoved() -> Bool { false }

    /// Match the AX window to public WindowServer metadata, failing closed on
    /// missing or ambiguous matches. Bounds use the same global top-down space.
    private static func uniqueWindowID(pid: pid_t, bounds: CGRect) -> CGWindowID? {
        guard let matches = matchingCGWindowIDs(pid: pid, bounds: bounds) else { return nil }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func matchingCGWindowIDs(pid: pid_t, bounds: CGRect) -> [CGWindowID]? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return nil }
        let matches: [CGWindowID] = windows.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary),
                  close(frame, to: bounds),
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  number.uint32Value != kCGNullWindowID else { return nil }
            return number.uint32Value
        }
        return matches
    }

    /// Native scrollbars can accept AX value changes even when a posted Quartz
    /// wheel event is ignored by an app (observed with TextEdit). Prefer a value
    /// step derived from the document view's AX size so adjacent captures overlap.
    /// Otherwise use the scrollbar's own increment/decrement action. A return of
    /// false leaves the process-directed Quartz event as the last available route.
    private func scrollWithNativeScrollbar(pixels: Int) -> Bool {
        let budget = Budget(seconds: 0.6)
        guard let bar = Self.element(content, kAXVerticalScrollBarAttribute, budget: budget),
              let before = Self.scrollbarState(content, budget: budget) else { return false }
        let descending = pixels < 0
        let boundary = descending ? before.maximum : before.minimum
        if abs(before.value - boundary) <= 0.000_001 { return true }

        if let height = Self.documentHeight(in: content, viewport: visibleContentRect.height,
                                            budget: budget), budget.available {
            let travel = height - visibleContentRect.height
            let stepPixels = min(Double(abs(pixels)), Double(visibleContentRect.height) * 0.45)
            let rawStep = (before.maximum - before.minimum) * stepPixels / travel
            let next = descending ? min(boundary, before.value + rawStep)
                                  : max(boundary, before.value - rawStep)
            var settable = DarwinBoolean(false)
            AXUIElementSetMessagingTimeout(bar, Self.axQueryTimeout)
            if AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
               settable.boolValue, budget.available {
                let write = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                                         NSNumber(value: next))
                if write == .success {
                    // A native write may apply asynchronously. One accepted
                    // request owns this cycle; the settled frame verifies it.
                    // A step clamped at the document boundary is shorter than
                    // the requested movement. Keep rollback at that issued
                    // distance so a rejected bottom frame cannot overshoot
                    // the last accepted position.
                    let issuedPixels = abs(next - before.value) * travel / (before.maximum - before.minimum)
                    lastScrollMagnitude = max(1, Int(issuedPixels.rounded(.down)))
                    return true
                }
            }
        }

        // AXIncrement/AXDecrement are public scrollbar actions. Query supported
        // actions first; a successful call alone is not proof of movement.
        guard budget.available else { return false }
        var actions: CFArray?
        AXUIElementSetMessagingTimeout(bar, Self.axQueryTimeout)
        guard AXUIElementCopyActionNames(bar, &actions) == .success,
              let names = actions as? [String],
              names.contains(descending ? kAXIncrementAction : kAXDecrementAction) else { return false }
        let action = descending ? kAXIncrementAction : kAXDecrementAction
        guard budget.available, AXUIElementPerformAction(bar, action as CFString) == .success else {
            return false
        }
        // Do not immediately send another input because the value has not yet
        // changed. The capture policy checks movement after its settle interval.
        lastScrollMagnitude = abs(pixels)
        return true
    }

    /// The scroll area's AXContents are the document views, excluding its bars.
    /// Require a plausible full-height child before converting pixels to a bar
    /// fraction. Without one, never guess a fraction for an arbitrarily long page.
    private static func documentHeight(in content: AXUIElement, viewport: CGFloat,
                                       budget: Budget) -> Double? {
        guard budget.available else { return nil }
        var values: CFArray?
        AXUIElementSetMessagingTimeout(content, axQueryTimeout)
        let result = AXUIElementCopyAttributeValues(content, kAXContentsAttribute as CFString,
                                                    0, 8, &values)
        budget.record(result)
        guard result == .success, let values else { return nil }
        var largest: CGFloat = 0
        for value in values as NSArray {
            guard budget.available else { return nil }
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID(),
                  let rect = frame(cfValue as! AXUIElement, budget: budget) else { continue }
            largest = max(largest, rect.height)
        }
        guard largest.isFinite, largest > viewport * 1.2,
              largest < 10_000_000 else { return nil }
        return Double(largest)
    }

    /// Prefer the native scrollbar. If unavailable, derive a fraction only when
    /// the same validated AXWebArea exposes its full-document frame.
    func verticalScrollFraction() -> Double? {
        guard isCurrent() else { return nil }
        if let fraction = nativeVerticalScrollFraction() { return fraction }
        guard Self.string(identitySource, kAXRoleAttribute) == "AXWebArea",
              let documentFrame = Self.frame(identitySource) else { return nil }
        return CaptureScrollGeometry.fraction(documentFrame: documentFrame,
                                              viewportFrame: visibleContentRect)
    }

    /// Read only the native scrollbar fraction. Boundary evidence must not use
    /// inferred document geometry when deciding whether capture may begin.
    func nativeVerticalScrollFraction() -> Double? {
        guard isCurrent() else { return nil }
        return Self.scrollbarState(content)?.fraction
    }

    /// Move only to an exact endpoint through a writable native AX scrollbar.
    /// False means unsupported or unverified; no keyboard shortcuts are sent.
    @discardableResult
    func moveToTopIfSupported() -> Bool {
        moveToBoundaryIfSupported(fraction: 0)
    }

    @discardableResult
    func moveToBoundaryIfSupported(fraction: Double) -> Bool {
        guard fraction == 0 || fraction == 1,
              isCurrent(), let state = Self.scrollbarState(content),
              let bar = Self.element(content, kAXVerticalScrollBarAttribute) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        let boundary = fraction == 0 ? state.minimum : state.maximum
        guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                           NSNumber(value: boundary)) == .success,
              isCurrent(),
              let verified = Self.scrollbarState(content),
              abs(verified.minimum - state.minimum) <= 0.001,
              abs(verified.maximum - state.maximum) <= 0.001 else { return false }
        return fraction == 0 ? verified.fraction <= 0.001 : verified.fraction >= 0.999
    }

    /// Restore only when the same document and the same AX scrollbar range remain.
    @discardableResult
    func restoreInitialScrollPositionIfSupported() -> Bool {
        guard isCurrent(), let initial = initialScrollState,
              let current = Self.scrollbarState(content),
              abs(current.minimum - initial.minimum) <= 0.001,
              abs(current.maximum - initial.maximum) <= 0.001,
              let bar = Self.element(content, kAXVerticalScrollBarAttribute) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue,
              AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString,
                                           NSNumber(value: initial.value)) == .success,
              let restored = verticalScrollFraction() else { return false }
        return abs(restored - initial.fraction) <= 0.001
    }

    private static func scrollbarState(_ content: AXUIElement, budget: Budget? = nil) -> ScrollbarState? {
        guard let bar = element(content, kAXVerticalScrollBarAttribute, budget: budget),
              number(bar, kAXEnabledAttribute, budget: budget) == 1,
              let value = number(bar, kAXValueAttribute, budget: budget), value.isFinite else { return nil }
        let reportedMin = number(bar, kAXMinValueAttribute, budget: budget)
        let reportedMax = number(bar, kAXMaxValueAttribute, budget: budget)
        let minimum: Double
        let maximum: Double
        if let reportedMin, let reportedMax {
            minimum = reportedMin
            maximum = reportedMax
        } else if reportedMin == nil, reportedMax == nil, (0...1).contains(value) {
            minimum = 0
            maximum = 1
        } else {
            return nil
        }
        guard minimum.isFinite, maximum.isFinite, maximum > minimum,
              value >= minimum - 0.001, value <= maximum + 0.001 else { return nil }
        return ScrollbarState(value: min(max(value, minimum), maximum),
                              minimum: minimum, maximum: maximum)
    }

    private static func hitContent(in app: AXUIElement, window: AXUIElement,
                                   windowRect: CGRect,
                                   at point: CGPoint, budget: Budget) -> (AXUIElement, String, CGRect, AXUIElement)? {
        var hit: AXUIElement?
        guard budget.available else { return nil }
        let result = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        budget.record(result)
        guard result == .success,
              let hit, isDescendant(hit, of: window, budget: budget) else { return nil }
        var cursor: AXUIElement? = hit
        var seen: [AXUIElement] = []
        var webArea: (AXUIElement, String, CGRect)?
        for _ in 0..<CaptureAncestryWalk.maximumNodes {
            guard budget.available else { return nil }
            guard let node = cursor, !seen.contains(where: { CFEqual($0, node) }) else { break }
            seen.append(node)
            if let role = scrollRole(node, budget: budget), let rect = frame(node, budget: budget) {
                let visible = rect.intersection(windowRect)
                if visible.contains(point), visible.width >= 200, visible.height >= 160,
                   visible.width * visible.height >= 64_000 {
                    if role == kAXScrollAreaRole {
                        return (node, role, rect, webArea?.0 ?? node)
                    }
                    if webArea == nil { webArea = (node, role, rect) }
                }
            }
            if CFEqual(node, window) { break }
            cursor = element(node, kAXParentAttribute, budget: budget)
        }
        if let webArea { return (webArea.0, webArea.1, webArea.2, webArea.0) }
        return nil
    }

    /// Electron hit testing can skip a named ARIA region. Validate against the
    /// frozen window, and reject nested interactive targets rather than requiring
    /// that optional semantic group to occur in every native hit-test ancestry.
    private static func usableChatPoint(_ point: CGPoint, app: AXUIElement,
                                        window: AXUIElement, chatBounds: CGRect, budget: Budget) -> Bool {
        guard chatBounds.contains(point), budget.available else { return false }
        var hit: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        budget.record(result)
        guard result == .success, let hit,
              isDescendant(hit, of: window, budget: budget) else { return false }
        var cursor: AXUIElement? = hit
        var seen: [AXUIElement] = []
        for _ in 0..<CaptureAncestryWalk.maximumNodes {
            guard budget.available, let node = cursor,
                  !seen.contains(where: { CFEqual($0, node) }),
                  let role = string(node, kAXRoleAttribute, budget: budget) else { return false }
            seen.append(node)
            if CaptureChatRegion.isInteractiveRole(role) { return false }
            if role == kAXScrollAreaRole {
                guard let rect = frame(node, budget: budget), rect.contains(chatBounds) else { return false }
            }
            if role == "AXWebArea" || CFEqual(node, window) { return true }
            cursor = element(node, kAXParentAttribute, budget: budget)
        }
        return false
    }

    /// Chat panes are often AX groups inside a window-sized web area, rather
    /// than AXScrollAreas. Their explicit container names identify the crop;
    /// normal target resolution still binds scrolling to the original document.
    private static func chatContentRect(application: NSRunningApplication, app: AXUIElement,
                                        window: AXUIElement, windowRect: CGRect, pointer: CGPoint,
                                        budget: Budget) -> CGRect? {
        guard let bundle = application.bundleIdentifier,
              CaptureChatRegion.isSupportedApplication(bundle) else { return nil }
        chatRegionDiagnostic = ["route": "searching"]
        func candidate(_ node: AXUIElement) -> CGRect? {
            guard let role = string(node, kAXRoleAttribute, budget: budget),
                  CaptureChatRegion.labelStrength(bundleIdentifier: bundle, role: role,
                      description: string(node, kAXDescriptionAttribute, budget: budget),
                      title: string(node, kAXTitleAttribute, budget: budget), help: nil, identifier: nil) > 0,
                  let rect = frame(node, budget: budget) else { return nil }
            chatRegionDiagnostic["namedRole"] = role
            chatRegionDiagnostic["namedFrame"] = "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)"
            return rect
        }
        var pane: (rect: CGRect, path: [AXUIElement])?
        var hitPath: [AXUIElement] = []
        guard budget.available else { return nil }
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(app, Float(pointer.x), Float(pointer.y), &hit)
        budget.record(hitResult)
        if hitResult == .success {
            var cursor = hit
            var path: [AXUIElement] = []
            var matches: [(CGRect, AXUIElement)] = []
            for _ in 0..<CaptureAncestryWalk.maximumNodes {
                guard budget.available, let node = cursor,
                      !path.contains(where: { CFEqual($0, node) }) else { break }
                path.append(node)
                if let rect = candidate(node) { matches.append((rect, node)) }
                if CFEqual(node, window) {
                    hitPath = path
                    if let rect = CaptureChatRegion.selectedRect(candidates: matches.map(\.0), windowBounds: windowRect, pointer: pointer),
                       let match = matches.first(where: { $0.0.intersection(windowRect) == rect }),
                       let index = path.firstIndex(where: { CFEqual($0, match.1) }) {
                        pane = (rect, Array(path[index...].reversed()))
                        chatRegionDiagnostic["route"] = "ancestry"
                    }
                    break
                }
                cursor = element(node, kAXParentAttribute, budget: budget)
            }
        }
        if pane == nil {
            // Fallback lookup only finds the pane. It does not walk its messages
            // or require a scan of all app controls before inspecting the composer.
            var stack: [(AXUIElement, [AXUIElement])] = [(window, [window])]
            var seen: [AXUIElement] = []
            let leaves: Set<String> = [kAXStaticTextRole, kAXButtonRole, kAXTextFieldRole,
                                       kAXTextAreaRole, kAXImageRole, kAXMenuItemRole,
                                       kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole]
            while budget.available, seen.count < 128, let (node, path) = stack.popLast() {
                guard !seen.contains(where: { CFEqual($0, node) }) else { continue }
                seen.append(node)
                if let rect = candidate(node),
                   let clipped = CaptureChatRegion.selectedRect(candidates: [rect], windowBounds: windowRect, pointer: pointer),
                   clipped.contains(pointer) {
                    pane = (clipped, path)
                    chatRegionDiagnostic["route"] = "window_point_search"
                    break
                }
                guard let role = string(node, kAXRoleAttribute, budget: budget), !leaves.contains(role) else { continue }
                // A sidebar can contain hundreds of accessible chat rows before
                // the transcript in source order. Exclude verified app chrome,
                // and unrelated list panes, before spending the lookup budget.
                let label = string(node, kAXDescriptionAttribute, budget: budget)
                let listFrame = [kAXListRole, kAXOutlineRole].contains(role) &&
                    !hitPath.contains(where: { CFEqual($0, node) }) ? frame(node, budget: budget) : nil
                if CaptureChatRegion.excludesLookupBranch(bundleIdentifier: bundle,
                    role: role, description: label,
                    frame: listFrame, pointer: pointer) { continue }
                if path.count < CaptureAncestryWalk.maximumNodes {
                    for child in children(node, budget: budget).reversed() where stack.count < 128 {
                        stack.append((child, path + [child]))
                    }
                }
            }
            chatRegionDiagnostic["lookupVisited"] = String(seen.count)
        }
        guard let pane, budget.available else {
            chatRegionDiagnostic["route"] = budget.available ? "pane_not_found" : "budget_exhausted"
            return nil
        }

        // For a sibling B off the pane's actual ancestor path, every descendant
        // has that same B as its LCA composer branch. Its frame can therefore
        // reject an irrelevant branch before traversing any of its controls.
        var visited = pane.path
        var branchesSeen: [AXUIElement] = []
        var overlays: [CGRect] = []
        var eligibleBranches = 0
        var controlMatches = 0
        func completeChildren(_ owner: AXUIElement) -> [AXUIElement]? {
            guard budget.available else { return nil }
            AXUIElementSetMessagingTimeout(owner, budget.messagingTimeout)
            var count: CFIndex = 0
            let result = AXUIElementGetAttributeValueCount(owner, kAXChildrenAttribute as CFString, &count)
            budget.record(result)
            chatRegionDiagnostic["childrenCountResult"] = String(result.rawValue)
            chatRegionDiagnostic["childrenCount"] = String(count)
            guard result == .success, count >= 0, count <= 32 else { return nil }
            if count == 0 { return [] }
            guard budget.available else { return nil }
            var values: CFArray?
            let copied = AXUIElementCopyAttributeValues(owner, kAXChildrenAttribute as CFString, 0, count, &values)
            budget.record(copied)
            chatRegionDiagnostic["childrenCopyResult"] = String(copied.rawValue)
            guard copied == .success, let values else { return nil }
            let nodes = (values as NSArray).compactMap { value -> AXUIElement? in
                let raw = value as CFTypeRef
                return CFGetTypeID(raw) == AXUIElementGetTypeID() ? (raw as! AXUIElement) : nil
            }
            return nodes.count == count ? nodes : nil
        }
        func containsComposerControl(_ root: AXUIElement, depth: Int) -> Bool? {
            var stack: [(AXUIElement, Int)] = [(root, depth)]
            while budget.available, let next = stack.last {
                guard visited.count < 128 else { return nil }
                stack.removeLast()
                let (node, level) = next
                if visited.contains(where: { CFEqual($0, node) }) { continue }
                visited.append(node)
                guard let role = string(node, kAXRoleAttribute, budget: budget) else { return nil }
                if bundle == "com.openai.codex", CaptureChatRegion.isInteractiveRole(role) { return true }
                if bundle == "com.anthropic.claudefordesktop", role == kAXTextAreaRole {
                    guard let description = string(node, kAXDescriptionAttribute, budget: budget) else { return nil }
                    if description == "Prompt" { return true }
                }
                let leaves: Set<String> = [kAXStaticTextRole, kAXButtonRole, kAXTextFieldRole,
                    kAXTextAreaRole, kAXImageRole, kAXMenuItemRole, kAXCheckBoxRole,
                    kAXRadioButtonRole, kAXPopUpButtonRole]
                if leaves.contains(role) { continue }
                guard level < CaptureAncestryWalk.maximumNodes, let descendants = completeChildren(node) else { return nil }
                for child in descendants.reversed() {
                    guard stack.count < 128 else { return nil }
                    stack.append((child, level + 1))
                }
            }
            return budget.available ? false : nil
        }
        for index in 0..<(pane.path.count - 1) {
            chatRegionDiagnostic["composerPathIndex"] = String(index)
            chatRegionDiagnostic["composerPathCount"] = String(pane.path.count)
            guard budget.available else { chatRegionDiagnostic["route"] = "composer_budget_exhausted"; return nil }
            let parent = pane.path[index]
            let next = pane.path[index + 1]
            guard let siblings = completeChildren(parent),
                  siblings.contains(where: { CFEqual($0, next) }) else {
                chatRegionDiagnostic["route"] = "composer_children_incomplete"
                return nil
            }
            for branch in siblings where !CFEqual(branch, next) {
                if pane.path.contains(where: { CFEqual($0, branch) }) ||
                   branchesSeen.contains(where: { CFEqual($0, branch) }) { continue }
                branchesSeen.append(branch)
                let geometry = CaptureChatRegion.composerBranch(frame: frame(branch, budget: budget), pane: pane.rect)
                if geometry == .irrelevant { continue }
                eligibleBranches += 1
                guard let hasControl = containsComposerControl(branch, depth: index + 1) else {
                    chatRegionDiagnostic["route"] = "composer_search_incomplete"
                    return nil
                }
                guard hasControl else { continue }
                controlMatches += 1
                guard case .overlay(let bounds) = geometry else {
                    chatRegionDiagnostic["route"] = "composer_geometry_unknown"
                    return nil
                }
                if !overlays.contains(bounds) { overlays.append(bounds) }
            }
        }
        chatRegionDiagnostic.merge(["candidates": "1", "composerBranches": String(overlays.count),
            "eligibleBranches": String(eligibleBranches), "composerCount": String(controlMatches),
            "visited": String(visited.count)], uniquingKeysWith: { _, new in new })
        guard budget.available, overlays.count <= 1 else {
            chatRegionDiagnostic["route"] = budget.available ? "composer_ambiguous" : "composer_budget_exhausted"
            return nil
        }
        let result: CGRect
        if let fixed = overlays.first {
            result = CaptureChatRegion.excludingBottomOverlay(fixed, from: pane.rect)
            chatRegionDiagnostic["composerExcluded"] = "true"
            chatRegionDiagnostic["composerFrame"] = "\(fixed.minX),\(fixed.minY),\(fixed.width),\(fixed.height)"
        } else { result = pane.rect }
        return CaptureChatRegion.selectedRect(candidates: [result], windowBounds: windowRect, pointer: pointer)
    }

    private static func largestWindowContent(in window: AXUIElement,
                                             windowRect: CGRect, budget: Budget) -> (AXUIElement, String, CGRect, AXUIElement)? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        var seen: [AXUIElement] = []
        var best: (AXUIElement, String, CGRect, AXUIElement)?
        var bestScore: CGFloat = 0
        while budget.available && index < queue.count && index < 128 {
            let (node, depth) = queue[index]
            index += 1
            guard !seen.contains(where: { CFEqual($0, node) }) else { continue }
            seen.append(node)
            if let role = scrollRole(node, budget: budget), let rect = frame(node, budget: budget) {
                let visible = rect.intersection(windowRect)
                let area = visible.isNull ? 0 : visible.width * visible.height
                // Popovers, combo lists, and incidental sidebar scrollers should
                // not become a whole-page target when the pointer is on chrome.
                if visible.width >= 240, visible.height >= 180,
                   area >= max(100_000, windowRect.width * windowRect.height * 0.25),
                   area * (role == kAXScrollAreaRole ? 1.1 : 1) > bestScore {
                    best = (node, role, rect, node)
                    bestScore = area * (role == kAXScrollAreaRole ? 1.1 : 1)
                }
            }
            if depth < 8 {
                for child in children(node, budget: budget).prefix(max(0, 128 - queue.count)) {
                    queue.append((child, depth + 1))
                }
            }
        }
        guard budget.available, let best else { return nil }
        let identitySource = best.1 == kAXScrollAreaRole
            ? (webIdentitySource(in: best.0, budget: budget) ?? best.0)
            : best.0
        return (best.0, best.1, best.2, identitySource)
    }

    private static func webIdentitySource(in content: AXUIElement, budget: Budget) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(content, 0)]
        var index = 0
        while budget.available && index < queue.count && index < 32 {
            let (node, depth) = queue[index]
            index += 1
            if string(node, kAXRoleAttribute, budget: budget) == "AXWebArea",
               attribute(node, kAXURLAttribute, budget: budget) != nil { return node }
            if depth < 4 {
                for child in children(node, budget: budget).prefix(max(0, 32 - queue.count)) {
                    queue.append((child, depth + 1))
                }
            }
        }
        return nil
    }

    private static func scrollRole(_ node: AXUIElement, budget: Budget? = nil) -> String? {
        guard let role = string(node, kAXRoleAttribute, budget: budget),
              role == kAXScrollAreaRole || role == "AXWebArea" else { return nil }
        return role
    }

    private static func documentIdentity(content: AXUIElement,
                                         window: AXUIElement, budget: Budget? = nil) -> DocumentIdentity? {
        if let rawURL = attribute(content, kAXURLAttribute, budget: budget),
           let url = (rawURL as? URL)?.absoluteString ?? (rawURL as? String),
           !url.isEmpty { return .url(url) }
        if let title = string(window, kAXTitleAttribute, budget: budget), !title.isEmpty {
            return .windowTitle(title)
        }
        return nil
    }

    private static func children(_ owner: AXUIElement, budget: Budget? = nil) -> [AXUIElement] {
        guard budget?.available ?? true else { return [] }
        AXUIElementSetMessagingTimeout(owner, axQueryTimeout)
        var values: CFArray?
        let result = AXUIElementCopyAttributeValues(owner, kAXChildrenAttribute as CFString,
                                                    0, 32, &values)
        budget?.record(result)
        guard result == .success,
              let values else { return [] }
        return (values as NSArray).compactMap { value in
            let cfValue = value as CFTypeRef
            return CFGetTypeID(cfValue) == AXUIElementGetTypeID() ? (cfValue as! AXUIElement) : nil
        }
    }

    private static func attribute(_ owner: AXUIElement, _ name: String, budget: Budget? = nil) -> CFTypeRef? {
        guard budget?.available ?? true else { return nil }
        AXUIElementSetMessagingTimeout(owner, budget?.messagingTimeout ?? axQueryTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(owner, name as CFString, &value)
        budget?.record(result)
        guard result == .success else { return nil }
        return value
    }

    private static func element(_ owner: AXUIElement, _ name: String, budget: Budget? = nil) -> AXUIElement? {
        guard let value = attribute(owner, name, budget: budget),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ owner: AXUIElement, _ attribute: String, budget: Budget? = nil) -> String? {
        guard budget?.available ?? true else { return nil }
        AXUIElementSetMessagingTimeout(owner, axQueryTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(owner, attribute as CFString, &value)
        budget?.record(result)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func number(_ owner: AXUIElement, _ attribute: String, budget: Budget? = nil) -> Double? {
        guard budget?.available ?? true else { return nil }
        AXUIElementSetMessagingTimeout(owner, axQueryTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(owner, attribute as CFString, &value)
        budget?.record(result)
        guard result == .success else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private static func frame(_ owner: AXUIElement, budget: Budget? = nil) -> CGRect? {
        guard budget?.available ?? true else { return nil }
        AXUIElementSetMessagingTimeout(owner, budget?.messagingTimeout ?? axQueryTimeout)
        var position: CFTypeRef?, size: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(owner, kAXPositionAttribute as CFString, &position)
        budget?.record(positionResult)
        guard positionResult == .success, budget?.available ?? true else { return nil }
        AXUIElementSetMessagingTimeout(owner, budget?.messagingTimeout ?? axQueryTimeout)
        let sizeResult = AXUIElementCopyAttributeValue(owner, kAXSizeAttribute as CFString, &size)
        budget?.record(sizeResult)
        guard sizeResult == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions).standardized
    }

    private static func isDescendant(_ node: AXUIElement, of ancestor: AXUIElement,
                                     budget: Budget? = nil) -> Bool {
        ancestryWalk(node, of: ancestor, budget: budget).containsTarget
    }

    private static func ancestryWalk(_ node: AXUIElement, of ancestor: AXUIElement,
                                     budget: Budget? = nil) -> CaptureAncestryWalk.Result {
        CaptureAncestryWalk.evaluate(from: node, matching: ancestor,
            isWithinBudget: { budget?.available ?? true },
            parent: { element($0, kAXParentAttribute, budget: budget) },
            equals: { CFEqual($0, $1) })
    }

    private static func display(overlapping rect: CGRect, pointer: CGPoint) -> (CGDirectDisplayID, CGRect)? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        var best: (CGDirectDisplayID, CGRect)?
        var bestArea: CGFloat = 0
        for id in ids.prefix(Int(count)) {
            let bounds = CGDisplayBounds(id)
            let overlap = bounds.intersection(rect)
            // A window may span monitors. Honor the selected viewport's screen
            // before falling back to the display with the largest intersection.
            if bounds.contains(pointer), !overlap.isNull, overlap.width >= 80, overlap.height >= 100 {
                return (id, bounds)
            }
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea { best = (id, bounds); bestArea = area }
        }
        return best
    }
}

/// Reject a marked session wheel unless WindowServer annotated the exact
/// originally selected process and window. Ordinary user input passes untouched.
private final class CaptureWheelGate {
    struct Receipt {
        var resolved = false
        var delivered = false
        var pid: pid_t = 0
        var magnitude = 0
        var diagnostic: [String: String] = [:]
    }
    let tag = Int64.random(in: 1...Int64.max)
    private let pid: pid_t
    private let windowID: CGWindowID
    private let lock = NSLock()
    private var current = Receipt()
    private var pending = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var available: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var receipt: Receipt { lock.lock(); defer { lock.unlock() }; return current }

    init?(pid: pid_t, windowID: CGWindowID) {
        self.pid = pid; self.windowID = windowID
        tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<CaptureWheelGate>.fromOpaque(context).takeUnretainedValue()
                    .receive(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return nil }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
    func prepare(magnitude: Int) {
        lock.lock(); defer { lock.unlock() }
        pending = true; current = Receipt(magnitude: magnitude)
    }
    func expire() { lock.lock(); pending = false; lock.unlock() }
    private func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.eventSourceUserData) == tag else {
            return Unmanaged.passUnretained(event)
        }
        let rawOwner = event.getIntegerValueField(.eventTargetUnixProcessID)
        let owner = pid_t(truncatingIfNeeded: rawOwner)
        let underPointer = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let capableWindow = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let appKitWindow = NSEvent(cgEvent: event)?.windowNumber
        let location = event.location
        let physicalPointer = CGEvent(source: nil)?.location
        lock.lock(); defer { lock.unlock() }
        // Native Chrome wheels can have zero in both pointer-window fields.
        // The public AppKit window number identifies the event's destination;
        // require a positive exact match, never treat missing identity as valid.
        let windowMatches = appKitWindow.map { $0 > 0 && $0 == Int(windowID) } ?? false
        let processMatches = rawOwner == Int64(pid)
        let accepted = pending && type == .scrollWheel && processMatches && windowMatches
        var mismatches: [String] = []
        if !pending { mismatches.append("pending_not_active") }
        if type != .scrollWheel { mismatches.append("event_type_changed") }
        if !processMatches { mismatches.append("process_id_changed") }
        if let appKitWindow, appKitWindow > 0 {
            if appKitWindow != Int(windowID) { mismatches.append("appkit_window_changed") }
        } else {
            mismatches.append("appkit_window_missing")
        }
        current.diagnostic = [
            "expected_pid": String(pid),
            "annotated_pid": String(rawOwner),
            "expected_window_id": String(windowID),
            "pointer_window_id": String(underPointer),
            "capable_window_id": String(capableWindow),
            "appkit_window_number": appKitWindow.map { String($0) } ?? "unavailable",
            "event_location_x": String(Double(location.x)),
            "event_location_y": String(Double(location.y)),
            "physical_pointer_x": physicalPointer.map { String(Double($0.x)) } ?? "unavailable",
            "physical_pointer_y": physicalPointer.map { String(Double($0.y)) } ?? "unavailable",
            "event_type": String(type.rawValue),
            "pending": String(pending),
            "mismatch": mismatches.isEmpty ? "none" : mismatches.joined(separator: ","),
        ]
        current.resolved = true; current.delivered = accepted; current.pid = owner
        pending = false
        return accepted ? Unmanaged.passUnretained(event) : nil
    }
}
