import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import ImageIO

/// Capture is explicit and local: only the selected region is sampled, during one session.
@MainActor @Observable
final class ScrollScreenshot: NSObject, NSWindowDelegate {
    static let shared = ScrollScreenshot()
    static let notification = "io.github.eroyun.dial.capture.scroll"
    var message = ""
    private(set) var captureDetails = ""
    var capturedSize = ""
    var result: NSImage?
    var copied = false
    private(set) var imageRevision = 0
    private(set) var isEditingImage = false
    private var imageEditTask: Task<Void, Never>?
    private var imageEditGeneration = UUID()
    private var resultPNG: Data?
    private var selectionWindows: [NSWindow] = []
    private var scopePicker: ScrollCaptureScopePicker?
    private var scopeSelectionReply: ((Result<ScrollCaptureScopeSelection, Error>) -> Void)?
    private var controls: NSPanel?
    private var preview: NSWindow?
    private var permissionWindow: NSWindow?
    private var captureErrorAlert: NSAlert?
    private var captureErrorActions: CaptureAlertActions?
    private var copyFeedback: NSPanel?
    private var copyFeedbackDismissal: Task<Void, Never>?
    private var hiddenWindows: [NSWindow] = []
    private var previousApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private(set) var automatic = true
    private(set) var capturePhase = "idle"
    private(set) var captureOutcome = "none"
    private var activeAutoTarget: AutoScrollTarget?
    private var captureApplicationIdentifier = ""
    private var scrollAttempts = 0
    private var lastScrollRoute = "none"
    private var lastScrollPauseReason = "none"
    private var lastScrollHitOwnerPID: Int32 = 0
    private var lastScrollDestinationDiagnostic: [String: String] = [:]
    private var lastTargetValidation = "none"
    private(set) var startPreparationEvidence = "none"
    private var startPreparationAttempts = 0
    private var boundaryVerification: [String: String] = [:]
    private var rollbackVerification: [String: String] = [:]
    private var rejectedAlignment: [String: String] = [:]
    private var traversalDirection = "none"
    private var acceptedCaptureFrames = 0
    private var lastStitchResult = "none"
    private var lastStitchRejection = ""
    private var captureRegion: [String: String] = [:]
    private var lastTargetEntryDiagnostic: [String: String] = [:]
    private var frameProof: CaptureFrameProof?
    private var task: Task<Void, Never>?
    private var session = UUID()
    private var finishRequested = false
    private var copyWhenDone = false
    private var singleShot = false
    private var isSelecting = false
    var canFinish: Bool { task != nil && !finishRequested && !capturedSize.isEmpty }

    override init() {
        super.init()
        lastExternalApplication = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor [weak self] in self?.lastExternalApplication = app }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openRequested(_:)), name: Notification.Name(Self.notification), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(statusRequested(_:)), name: Notification.Name(Self.notification + ".status"), object: nil)
    }

    isolated deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    @objc private func statusRequested(_ note: Notification) {
        guard let nonce = note.object as? String, UUID(uuidString: nonce) != nil else { return }
        let alertSize = captureErrorAlert?.window.frame.size ?? .zero
        let feedbackSize = copyFeedback?.frame.size ?? .zero
        let report: [String: Any] = ["phase": capturePhase, "outcome": captureOutcome, "active": task != nil || isSelecting,
                                    "automatic": automatic, "capturedSize": capturedSize, "copied": copied,
                                    "singleShot": singleShot, "selector": scopePicker?.status ?? [:],
                                    "isEditingImage": isEditingImage, "imageRevision": imageRevision,
                                    "message": message, "respondingPID": ProcessInfo.processInfo.processIdentifier,
                                    "sessionID": session.uuidString, "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
                                    "targetApplicationIdentifier": captureApplicationIdentifier, "scrollAttempts": scrollAttempts,
                                    "scrollRoute": lastScrollRoute, "targetValidation": lastTargetValidation,
                                    "startPreparationEvidence": startPreparationEvidence,
                                    "startPreparationAttempts": startPreparationAttempts,
                                    "boundaryVerification": boundaryVerification,
                                    "rollbackVerification": rollbackVerification,
                                    "rejectedAlignment": rejectedAlignment,
                                    "traversalDirection": traversalDirection, "acceptedCaptureFrames": acceptedCaptureFrames,
                                    "lastStitchResult": lastStitchResult, "lastStitchRejection": lastStitchRejection,
                                    "captureRegion": captureRegion,
                                    "targetEntry": lastTargetEntryDiagnostic,
                                    "chatRegion": AutoScrollTarget.chatRegionDiagnostic,
                                    "proofFrameCount": frameProof?.frameCount ?? 0,
                                    "proofIssue": frameProof?.issue ?? "",
                                    "scrollPauseReason": lastScrollPauseReason, "scrollHitOwnerPID": lastScrollHitOwnerPID,
                                    "scrollDestination": lastScrollDestinationDiagnostic,
                                    "errorAlertVisible": captureErrorAlert?.window.isVisible ?? false,
                                    "errorAlertSize": ["width": alertSize.width, "height": alertSize.height],
                                    "copyFeedbackVisible": copyFeedback?.isVisible ?? false,
                                    "copyFeedbackSize": ["width": feedbackSize.width, "height": feedbackSize.height]]
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(Self.notification + ".reply." + nonce), object: nil, userInfo: report, deliverImmediately: true)
    }

    @objc private func openRequested(_ note: Notification) {
        guard (note.userInfo?["targetPID"] as? NSNumber)?.int32Value == ProcessInfo.processInfo.processIdentifier else { return }
        if ["stop", "cancel"].contains(note.object as? String ?? ""), note.userInfo?["sessionID"] as? String != session.uuidString { return }
        switch note.object as? String {
        case "stop": if canFinish { finish() }
        case "cancel": if task != nil || isSelecting { cancel() } else { dismissCaptureError() }
        case "confirm-page", "confirm-window", "confirm-screen":
            guard note.userInfo?["sessionID"] as? String == session.uuidString,
                  isSelecting, let scopePicker else { return }
            _ = scopePicker.confirm(scopeName: String((note.object as? String ?? "").dropFirst(8)))
        case "snapshot", "copy-snapshot":
            guard task == nil, !isSelecting else { return }
            var requestedApplication: NSRunningApplication?
            if let identifier = note.userInfo?["applicationIdentifier"] as? String {
                let matching = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                guard matching.count == 1 else {
                    previousApplication = nil; singleShot = true
                    captureApplicationIdentifier = identifier
                    showError("Open one instance of the requested app, then start capture again."); return
                }
                requestedApplication = matching[0]
            }
            startSnapshot(copyWhenDone: note.object as? String == "copy-snapshot", application: requestedApplication)
        case "manual": start(automatic: false)
        case "manual-copy": start(copyWhenDone: true, automatic: false)
        default:
            guard task == nil, !isSelecting else { return }
            var requestedApplication: NSRunningApplication?
            if let identifier = note.userInfo?["applicationIdentifier"] as? String {
                let matching = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                guard matching.count == 1 else {
                    previousApplication = nil
                    captureApplicationIdentifier = identifier
                    showError("Open one instance of the requested app, then start capture again."); return
                }
                requestedApplication = matching[0]
            }
            start(copyWhenDone: note.object as? String == "copy", application: requestedApplication)
        }
    }

    func startSnapshot(copyWhenDone: Bool = false, application: NSRunningApplication? = nil) {
        start(copyWhenDone: copyWhenDone, application: application, screenshotOnly: true)
    }

    func start(copyWhenDone: Bool = false, automatic: Bool = true, application: NSRunningApplication? = nil, screenshotOnly: Bool = false) {
        guard task == nil, !isSelecting else { return }
        invalidateImageEdit()
        dismissCopyFeedback()
        dismissCaptureError()
        self.copyWhenDone = copyWhenDone
        self.automatic = automatic
        self.singleShot = screenshotOnly
        previousApplication = application ?? NSWorkspace.shared.frontmostApplication
        if previousApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousApplication = lastExternalApplication }
        captureApplicationIdentifier = previousApplication?.bundleIdentifier ?? ""
        scrollAttempts = 0
        lastScrollRoute = "none"
        lastScrollPauseReason = "none"
        lastScrollHitOwnerPID = 0
        lastScrollDestinationDiagnostic = [:]
        lastTargetValidation = "none"
        startPreparationEvidence = "none"
        startPreparationAttempts = 0
        boundaryVerification = [:]
        rollbackVerification = [:]
        rejectedAlignment = [:]
        traversalDirection = "none"; acceptedCaptureFrames = 0
        lastStitchResult = "none"; lastStitchRejection = ""; captureRegion = [:]
        lastTargetEntryDiagnostic = [:]
        AutoScrollTarget.resetEntryDiagnostic()
        frameProof = nil
        captureDetails = ""
        captureOutcome = "in_progress"
        guard CGPreflightScreenCaptureAccess() else {
            capturePhase = "permission_required"; captureOutcome = "permission_required"
            message = "Allow screen recording to capture this page or document."
            result = nil; resultPNG = nil; copied = false; capturedSize = ""
            showPermission(); return
        }
        permissionWindow?.orderOut(nil)
        preview?.orderOut(nil)
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0 != permissionWindow && $0 != preview }
        hiddenWindows.forEach { $0.orderOut(nil) }
        if automatic {
            session = UUID()
            finishRequested = false
            result = nil; resultPNG = nil; copied = false; capturedSize = ""
            message = "Finding the page…"
            capturePhase = "preparing"
            let token = session
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    if let application, !application.isTerminated {
                        try AutoScrollTarget.activateApplication(application)
                        let deadline = Date().addingTimeInterval(1)
                        while NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
                            guard token == self.session, !Task.isCancelled else { return }
                            guard Date() < deadline else {
                                throw CaptureFailure("Couldn’t bring the requested app forward. Switch to it and try again.")
                            }
                            try await Task.sleep(nanoseconds: 50_000_000)
                        }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard token == self.session, !Task.isCancelled else { return }
                    let choice = try await self.chooseScope(scrolling: !self.singleShot)
                    guard token == self.session, !Task.isCancelled else { return }
                    if let application, choice.application?.processIdentifier != application.processIdentifier {
                        throw CaptureFailure("Choose a page in the requested application.")
                    }
                    self.previousApplication = choice.application ?? self.previousApplication
                    if self.singleShot {
                        await self.captureStill(selection: choice, token: token)
                        return
                    }
                    guard let application = choice.application, let windowBounds = choice.windowBounds else {
                        throw CaptureFailure("Choose a scrollable page or window.")
                    }
                    self.previousApplication = application
                    self.captureApplicationIdentifier = application.bundleIdentifier ?? ""
                    NSApp.yieldActivation(to: application)
                    try AutoScrollTarget.activateWindow(application: application, bounds: windowBounds)
                    let deadline = Date().addingTimeInterval(1)
                    while true {
                        guard token == self.session, !Task.isCancelled else { return }
                        guard Date() < deadline else { throw CaptureFailure("Bring the selected page to the front, then try again.") }
                        if AutoScrollTarget.focusedWindowIsReady(application: application,
                            expectedWindowBounds: windowBounds, expectedWindowID: choice.windowID,
                            remainingSeconds: deadline.timeIntervalSinceNow) { break }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    guard token == self.session, !Task.isCancelled else { return }
                    let intersection = choice.rect.intersection(windowBounds)
                    guard !intersection.isNull, intersection.width >= 80, intersection.height >= 100 else {
                        throw CaptureFailure("Choose an area containing the scrollable page.")
                    }
                    let contentPoint = choice.isCustomArea
                        ? CapturePageSelection.contentPoint(rect: choice.rect, windowBounds: windowBounds)
                        : choice.selectionPoint
                    guard let contentPoint else { throw CaptureFailure("Choose an area inside the scrolling page.") }
                    let target = try AutoScrollTarget.resolve(application: application,
                        pointer: contentPoint,
                        expectedWindowBounds: windowBounds, expectedWindowID: choice.windowID,
                        chatBounds: choice.isChatRegion ? intersection : nil)
                    self.lastTargetEntryDiagnostic = AutoScrollTarget.lastEntryDiagnostic?.fields ?? [:]
                    self.lastTargetEntryDiagnostic["selection"] = choice.isCustomArea ? "custom-area" : "page"
                    self.lastTargetEntryDiagnostic["scrollPointPolicy"] = choice.isChatRegion ? "chat-tested-point" : choice.isCustomArea ? "crop-center" : "pointer"
                    self.lastTargetEntryDiagnostic["scrollPoint"] = "\(target.scrollPoint.x),\(target.scrollPoint.y)"
                    try target.configureCaptureRegion(intersection,
                        preferredScrollPoint: choice.isCustomArea ? contentPoint : nil)
                    guard let screen = NSScreen.screens.first(where: {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.displayID
                    }) else { throw CaptureFailure("The selected display is unavailable.") }
                    let displayBounds = CGDisplayBounds(target.displayID)
                    let localRect = CGRect(x: intersection.minX - displayBounds.minX,
                                           y: displayBounds.maxY - intersection.maxY,
                                           width: intersection.width, height: intersection.height)
                    self.activeAutoTarget = target
                    self.capturePhase = "preparing"
                    self.showControls(on: screen, selection: localRect, avoiding: target.scrollPoint)
                    await self.captureAutomatically(target: target, trimStationaryColumns: !choice.isCustomArea, token: token)
                } catch {
                    guard token == self.session, !Task.isCancelled else { return }
                    self.lastTargetEntryDiagnostic = AutoScrollTarget.lastEntryDiagnostic?.fields ?? [:]
                    self.activeAutoTarget?.restoreInitialScrollPositionIfSupported()
                    self.activeAutoTarget?.restorePointerIfUnmoved()
                    self.activeAutoTarget = nil
                    self.task = nil; self.controls?.orderOut(nil); self.controls = nil
                    self.capturePhase = "failed"
                    self.restoreWindows(); self.showError(error.localizedDescription)
                }
            }
            return
        }
        isSelecting = true
        capturePhase = "selecting"
        message = "Click for the full display, or drag to select page content and leave out fixed headers and sidebars. Esc to cancel."
        for screen in NSScreen.screens {
            let window = CaptureSelectionWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = CaptureSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.completed = { [weak self] rect in self?.selected(rect, on: screen) }
            window.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            selectionWindows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func chooseScope(scrolling: Bool) async throws -> ScrollCaptureScopeSelection {
        let picker = ScrollCaptureScopePicker()
        scopePicker = picker; isSelecting = true; capturePhase = "selecting"
        message = scrolling ? "Choose the scrolling area" : "Choose the screenshot area"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                scopeSelectionReply = { continuation.resume(with: $0) }
                picker.present(scrolling: scrolling,
                               resolveRegion: { application, point, bounds in
                                   AutoScrollTarget.previewContentRect(application: application, windowBounds: bounds, pointer: point)
                               },
                               onCapture: { [weak self, weak picker] selection in
                                   guard let self, let picker, self.scopePicker === picker else { return }
                                   self.completeScopeSelection(.success(selection))
                               },
                               onCancel: { [weak self, weak picker] in
                                   guard let self, let picker, self.scopePicker === picker else { return }
                                   self.cancel()
                               })
            }
        } onCancel: {
            Task { @MainActor [weak self, weak picker] in
                guard let self, let picker, self.scopePicker === picker else { return }
                self.completeScopeSelection(.failure(CancellationError()))
            }
        }
    }

    private func completeScopeSelection(_ result: Result<ScrollCaptureScopeSelection, Error>) {
        scopePicker?.close(); scopePicker = nil; isSelecting = false
        let reply = scopeSelectionReply; scopeSelectionReply = nil
        reply?(result)
    }

    private func captureStill(selection: ScrollCaptureScopeSelection, token: UUID) async {
        do {
            capturePhase = "preparing"; message = "Capturing screenshot…"
            let content: SCShareableContent = try await Self.boundedCapture { reply in
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                    if let content { reply(.success(content)) }
                    else { reply(.failure(error ?? CaptureFailure("Display discovery failed."))) }
                }
            }
            guard token == session, !Task.isCancelled else { return }
            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false; configuration.capturesAudio = false
            let filter: SCContentFilter
            let rect: CGRect
            let display = content.displays.max { a, b in
                let aa = a.frame.intersection(selection.rect), bb = b.frame.intersection(selection.rect)
                return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
            }
            guard let display else { throw CaptureFailure("The selected display is unavailable.") }
            let scale = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
            }?.backingScaleFactor ?? 1
            if !selection.isCustomArea, let windowID = selection.windowID {
                guard let expectedBounds = selection.windowBounds,
                      let window = content.windows.first(where: { $0.windowID == windowID }),
                      window.owningApplication?.processID == selection.application?.processIdentifier,
                      abs(window.frame.minX - expectedBounds.minX) <= 3,
                      abs(window.frame.minY - expectedBounds.minY) <= 3,
                      abs(window.frame.width - expectedBounds.width) <= 3,
                      abs(window.frame.height - expectedBounds.height) <= 3,
                      window.frame.contains(selection.rect) else {
                    throw CaptureFailure("The selected window changed. Select it again.")
                }
                if selection.rect == expectedBounds {
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    rect = CGRect(origin: .zero, size: window.frame.size)
                } else {
                    guard display.frame.contains(selection.rect) else {
                        throw CaptureFailure("Choose a screenshot area within one display.")
                    }
                    // Display-style filters support sourceRect; a single-window
                    // filter ignores it and would scale the whole window instead.
                    filter = SCContentFilter(display: display, including: [window])
                    rect = selection.rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    configuration.sourceRect = rect
                }
            } else {
                if let windowID = selection.windowID {
                    guard content.windows.contains(where: { $0.windowID == windowID && $0.owningApplication?.processID == selection.application?.processIdentifier }) else {
                        throw CaptureFailure("The selected window changed. Select it again.")
                    }
                }
                guard display.frame.contains(selection.rect) else {
                    throw CaptureFailure("Choose a screenshot area within one display.")
                }
                filter = SCContentFilter(display: display,
                    excludingApplications: content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }, exceptingWindows: [])
                rect = selection.rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                configuration.sourceRect = rect
            }
            configuration.width = Int((rect.width * scale).rounded())
            configuration.height = Int((rect.height * scale).rounded())
            guard configuration.width > 0, configuration.height > 0,
                  configuration.width * configuration.height <= 16_000_000 else {
                throw CaptureFailure("Choose a smaller screenshot area.")
            }
            guard Self.selectedWindowIsCurrent(selection) else { throw CaptureFailure("The selected window changed. Select it again.") }
            let image: CGImage = try await Self.boundedCapture { reply in
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                    if let image { reply(.success(image)) }
                    else { reply(.failure(error ?? CaptureFailure("Screen capture failed."))) }
                }
            }
            guard token == session, !Task.isCancelled else { return }
            guard Self.selectedWindowIsCurrent(selection) else { throw CaptureFailure("The selected window changed. Select it again.") }
            let encodedPNG = await Task.detached(priority: .userInitiated) {
                NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }.value
            guard let png = encodedPNG else { throw CaptureFailure("The screenshot could not be prepared. Try again.") }
            guard token == session, !Task.isCancelled else { return }
            resultPNG = png; result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            capturedSize = "\(image.width) × \(image.height) px"; imageRevision &+= 1
            capturePhase = "ready"; captureOutcome = "snapshot"; message = "Your screenshot is ready."
            task = nil; restoreWindows(); presentResult()
        } catch {
            guard token == session, !Task.isCancelled else { return }
            task = nil; restoreWindows(); showError(error.localizedDescription)
        }
    }

    private static func selectedWindowIsCurrent(_ selection: ScrollCaptureScopeSelection) -> Bool {
        guard let windowID = selection.windowID else { return true }
        guard let application = selection.application, let expected = selection.windowBounds,
              !application.isTerminated,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier,
              let rawBounds = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary) else { return false }
        return abs(bounds.minX - expected.minX) <= 3 && abs(bounds.minY - expected.minY) <= 3 &&
            abs(bounds.width - expected.width) <= 3 && abs(bounds.height - expected.height) <= 3
    }

    private func selected(_ rect: CGRect, on screen: NSScreen) {
        guard isSelecting else { return }
        let rect = rect.integral.intersection(CGRect(origin: .zero, size: screen.frame.size))
        guard rect.width > 0, rect.height > 0 else { return }
        guard rect.width * rect.height <= 8_000_000 else {
            closeSelection(); restoreWindows(); showError("Choose a smaller content area, below 8 million pixels."); return
        }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { cancel(); return }
        closeSelection()
        session = UUID()
        finishRequested = false
        result = nil
        resultPNG = nil
        copied = false
        capturedSize = ""
        message = "Preparing capture—keep the page still."
        capturePhase = "preparing"
        showControls(on: screen, selection: rect)
        if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication?.activate(options: [])
        }
        let token = session
        let sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        task = Task { [weak self] in await self?.capture(displayID: number.uint32Value, rect: sourceRect, token: token) }
    }

    private func capture(displayID: CGDirectDisplayID, rect: CGRect, token: UUID) async {
        let stitcher = ScrollStitcher()
        var finalMessage = ""
        var unmatchedMovement = false
        do {
            let content: SCShareableContent = try await Self.boundedCapture { reply in
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                    if let content { reply(.success(content)) } else { reply(.failure(error ?? CaptureFailure("Display discovery failed."))) }
                }
            }
            guard token == session, !Task.isCancelled else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureFailure("The selected display disconnected.") }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = rect
            configuration.width = Int(rect.width)
            configuration.height = Int(rect.height)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let deadline = Date().addingTimeInterval(120)
            while token == session, !Task.isCancelled {
                let finishing = finishRequested
                if finishing { try await Task.sleep(nanoseconds: 250_000_000) }
                let image: CGImage = try await Self.boundedCapture { reply in
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                        if let image { reply(.success(image)) } else { reply(.failure(error ?? CaptureFailure("Screen capture failed."))) }
                    }
                }
                let outcome = try await Task.detached(priority: .userInitiated) {
                    let frame = try Self.frame(from: image)
                    return (stitcher.append(frame), stitcher.width, stitcher.height)
                }.value
                guard token == session, !Task.isCancelled else { return }
                capturedSize = "\(outcome.1) × \(outcome.2) px"
                switch outcome.0 {
                case .first, .appended:
                    capturePhase = "scrolling"
                    unmatchedMovement = false
                    message = "Scroll down slowly. Click Done when you reach the end."
                case .unchanged: break
                case .rejected(let reason): message = reason; unmatchedMovement = true
                case .limitReached: finalMessage = "Capture limit reached. This preview contains the accepted portion."
                }
                if finishing || Date() >= deadline { if Date() >= deadline { finalMessage = "Two-minute limit reached. This preview contains the accepted portion." }; break }
                if case .limitReached = outcome.0 { break }
                try await Task.sleep(nanoseconds: 350_000_000)
            }
        } catch {
            guard token == session, !Task.isCancelled else { return }
            finalMessage = "Capture stopped: \(error.localizedDescription)"
        }
        guard token == session, !Task.isCancelled else { return }
        if finalMessage.isEmpty && unmatchedMovement { finalMessage = "Some movement could not be joined. This preview contains the accepted portion." }
        let image = await Task.detached(priority: .userInitiated) { stitcher.image() }.value
        guard token == session, !Task.isCancelled else { return }
        guard let image else {
            task = nil; controls?.orderOut(nil); controls = nil; restoreWindows()
            showError(finalMessage.isEmpty ? "No image was captured. Try again after checking screen capture permission." : finalMessage); return
        }
        message = copyWhenDone ? "Preparing to copy…" : "Preparing preview…"
        let png = await Task.detached(priority: .userInitiated) {
            NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        }.value
        guard token == session else { return }
        task = nil
        controls?.orderOut(nil); controls = nil; restoreWindows()
        resultPNG = png
        result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageRevision &+= 1
        message = finalMessage.isEmpty ? "Your scrolling screenshot is ready." : finalMessage
        captureDetails = message
        capturePhase = "ready"
        captureOutcome = finalMessage.isEmpty ? "manual_finished" : "partial"
        presentResult()
    }

    /// Keyboard mappings must not run while the region picker owns input.
    func cancelSelectionForInput() -> Bool {
        guard isSelecting else { return false }
        cancel()
        return true
    }

    private func captureAutomatically(target: AutoScrollTarget, trimStationaryColumns: Bool, token: UUID) async {
        let traversal = CaptureTraversal.choose(scrollFraction: target.verticalScrollFraction())
        traversalDirection = traversal.rawValue
        captureRegion = ["width": String(describing: target.sourceRect.width), "height": String(describing: target.sourceRect.height),
                         "viewportWidth": String(describing: target.visibleContentRect.width), "viewportHeight": String(describing: target.visibleContentRect.height)]
        let stitcher = ScrollingImageStitcher(maximumPixels: AutoScrollPolicy.Limits.wholePage.pixels,
                                             maximumHeight: 1_000_000,
                                             maximumFrames: AutoScrollPolicy.Limits.wholePage.frames,
                                             captureUpward: traversal.capturesUp,
                                             trimStationaryColumns: trimStationaryColumns)
        let started = Date()
        var acceptedReference: ScrollCaptureFrame?
        var boundaryContentRect: CGRect?
        var proofSourceFilter = "unconfigured"
        frameProof = CaptureFrameProof(directoryPath: ProcessInfo.processInfo.environment[CaptureFrameProof.environmentKey],
                                       publicFixture: target.isPublicFrameProofFixture)
        func recordProof(_ frame: ScrollCaptureFrame, label: String) {
            frameProof?.record(frame, label: label, metadata: [
                "sessionID": token.uuidString, "displayID": String(target.displayID),
                "targetPID": String(target.pid), "windowID": target.targetWindowID.map(String.init) ?? "unavailable",
                "scrollAttempts": String(scrollAttempts), "scrollRoute": lastScrollRoute,
                "issuedMagnitude": String(target.lastScrollMagnitude), "showsCursor": "false",
                "sourceFilter": proofSourceFilter
            ])
        }
        var finalMessage = ""
        var startConfirmed = false
        do {
            let content: SCShareableContent = try await Self.boundedCapture { reply in
                SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, error in
                    if let content { reply(.success(content)) }
                    else { reply(.failure(error ?? CaptureFailure("Display discovery failed."))) }
                }
            }
            guard token == session, !Task.isCancelled else { return }
            guard target.isCurrent(), let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw AutoScrollTarget.Failure.contentChanged
            }
            guard content.applications.contains(where: { $0.processID == target.pid }) else {
                throw CaptureFailure("The original application is unavailable for capture.")
            }
            // Keep display-local coordinates, but include only the frozen
            // selected window for page/window crops. This also excludes our
            // controls when application exclusion metadata is incomplete.
            let dialApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter: SCContentFilter
            let globalCrop = target.sourceRect.offsetBy(dx: CGDisplayBounds(target.displayID).minX,
                                                       dy: CGDisplayBounds(target.displayID).minY)
            if target.windowRect.contains(globalCrop) {
                guard let selectedID = target.targetWindowID,
                      let selectedWindow = content.windows.first(where: {
                          $0.windowID == selectedID && $0.owningApplication?.processID == target.pid
                      }) else { throw AutoScrollTarget.Failure.windowChanged }
                filter = SCContentFilter(display: display, including: [selectedWindow])
                proofSourceFilter = "selected-window"
            } else {
                filter = SCContentFilter(display: display, excludingApplications: dialApplications, exceptingWindows: [])
                proofSourceFilter = "selected-display"
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = target.sourceRect
            let scale = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.displayID
            })?.backingScaleFactor ?? 1
            configuration.width = Int((target.sourceRect.width * scale).rounded())
            configuration.height = Int((target.sourceRect.height * scale).rounded())
            guard configuration.width > 0, configuration.height > 0,
                  configuration.width <= 8_000_000 / configuration.height else {
                throw CaptureFailure("Choose a smaller area to preserve full-resolution text.")
            }
            configuration.showsCursor = false
            configuration.capturesAudio = false

            func readFrame(timeout: TimeInterval = 8) async throws -> ScrollCaptureFrame {
                guard token == session, !Task.isCancelled else { throw CancellationError() }
                guard target.isCurrent() else { throw AutoScrollTarget.Failure.contentChanged }
                let image: CGImage = try await Self.boundedCapture(timeout: timeout) { reply in
                    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                        if let image { reply(.success(image)) }
                        else { reply(.failure(error ?? CaptureFailure("Screen capture failed."))) }
                    }
                }
                guard token == session, !Task.isCancelled else { throw CancellationError() }
                // Never append an observation after focus or the document changed.
                guard target.isCurrent() else { throw AutoScrollTarget.Failure.contentChanged }
                return try await Task.detached(priority: .userInitiated) {
                    CaptureBorderRepair.repair(try Self.frame(from: image))
                }.value
            }

            // A changing thumbnail must not prevent the first/top frame from
            // becoming a provisional reference. Later downward observations
            // still have to pass the stitcher's strict overlap verification.
            func readSettledFrame(before outerDeadline: Date? = nil) async throws -> ScrollCaptureFrame {
                let firstTimeout = min(8, outerDeadline?.timeIntervalSinceNow ?? 8)
                guard firstTimeout > 0 else { throw CaptureTimeout() }
                var previous = try await readFrame(timeout: firstTimeout)
                let deadline = min(Date().addingTimeInterval(1.2), outerDeadline ?? .distantFuture)
                while Date() < deadline {
                    if finishRequested { return previous }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    guard token == session, !Task.isCancelled else { throw CancellationError() }
                    if finishRequested { return previous }
                    let remaining = deadline.timeIntervalSinceNow
                    // Do not start a capture with a deadline shorter than a
                    // realistic follow-up observation. Its timeout would throw
                    // away the valid, identity-checked frame above.
                    guard remaining >= 0.25 else { break }
                    let next: ScrollCaptureFrame
                    do { next = try await readFrame(timeout: remaining) }
                    catch is CaptureTimeout { break }
                    let before = previous
                    let stable = await Task.detached(priority: .userInitiated) {
                        Self.appearsStable(before, next)
                    }.value
                    if stable { return next }
                    previous = next
                }
                return previous
            }

            // One delivered wheel owns this observation window. A rejected or
            // initially unchanged frame may be a stale/lazy-rendered sample;
            // retry captures at the same position before policy can request
            // rollback or another downward wheel. Rejected appends are inert.
            func observeAfterScroll() async throws -> (ScrollStitcher.AppendResult, Int, Int) {
                // The first capture uses its normal timeout; only additional
                // observations are bounded to 1.2 seconds after that sample.
                var deadline: Date?
                var lastOutcome: (ScrollStitcher.AppendResult, Int, Int)?
                while true {
                    guard token == session, !Task.isCancelled else { throw CancellationError() }
                    if finishRequested, let lastOutcome { return lastOutcome }
                    if let lastOutcome {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        guard token == session, !Task.isCancelled else { throw CancellationError() }
                        if finishRequested { return lastOutcome }
                    }
                    let candidate: ScrollCaptureFrame
                    if lastOutcome == nil {
                        candidate = try await readFrame()
                        deadline = Date().addingTimeInterval(1.2)
                    } else {
                        let remaining = (deadline ?? Date()).timeIntervalSinceNow
                        guard let lastOutcome else { throw CancellationError() }
                        guard remaining >= 0.25 else { return lastOutcome }
                        do { candidate = try await readFrame(timeout: remaining) }
                        catch is CaptureTimeout { return lastOutcome }
                    }
                    guard token == session, !Task.isCancelled else { throw CancellationError() }
                    guard target.isCurrent() else { throw AutoScrollTarget.Failure.contentChanged }
                    recordProof(candidate, label: "observation")
                    let outcome = await Task.detached(priority: .userInitiated) {
                        (stitcher.append(candidate), stitcher.width, stitcher.height)
                    }.value
                    guard token == session, !Task.isCancelled else { throw CancellationError() }
                    acceptedCaptureFrames = stitcher.frameCount
                    lastStitchResult = String(describing: outcome.0)
                    if case .rejected(let reason) = outcome.0 {
                        lastStitchRejection = reason
                        rejectedAlignment = stitcher.lastAlignment
                    }
                    switch outcome.0 {
                    case .first, .appended:
                        acceptedReference = candidate
                        return outcome
                    case .limitReached: return outcome
                    case .unchanged, .rejected: lastOutcome = outcome
                    }
                }
            }

            // Retry only the operation that has not issued a wheel event. Keeping
            // this wait inside each recovery stage prevents a repeated rollback.
            func performScroll(_ operation: () throws -> Void, beforeAttempt: (() throws -> Void)? = nil) async throws -> Bool {
                let preparationDeadline = Date().addingTimeInterval(1)
                while true {
                    guard token == session, !Task.isCancelled else { throw CancellationError() }
                    if finishRequested { return false }
                    guard target.isCurrent() else { throw AutoScrollTarget.Failure.contentChanged }
                    try beforeAttempt?()
                    scrollAttempts += 1
                    try operation()
                    try await target.waitForScrollDelivery()
                    lastScrollRoute = target.lastScrollRoute
                    lastScrollPauseReason = target.lastScrollPauseReason
                    lastScrollHitOwnerPID = target.lastSystemHitOwnerPID ?? 0
                    lastScrollDestinationDiagnostic = target.lastScrollDestinationDiagnostic
                    // A native scrollbar can report zero at its endpoint; that
                    // still permits a frame observation. An unposted HID cannot.
                    if target.lastScrollMagnitude == 0 {
                        if target.lastScrollRoute == "quartz-process-paused" || target.lastScrollRoute == "quartz-session-paused" {
                            throw CaptureFailure("The selected window could not receive scrolling. Choose its page content and try again.")
                        }
                        if target.lastScrollRoute == "quartz-hid-preparing" {
                            guard Date() < preparationDeadline else {
                                throw CaptureFailure("The pointer could not be prepared for scrolling.")
                            }
                            capturePhase = "preparing"
                            message = "Preparing to scroll… Stop to finish early."
                            try await Task.sleep(nanoseconds: 50_000_000)
                            continue
                        }
                    }
                    capturePhase = "scrolling"
                    return true
                }
            }

            let boundaryName = traversal.preparesUp ? "top" : "bottom"
            message = "Moving to the \(boundaryName) of the page…"
            let jumpedToBoundary = target.moveToBoundaryIfSupported(fraction: traversal.startBoundaryFraction)
            startConfirmed = jumpedToBoundary
            startPreparationEvidence = jumpedToBoundary ? "observed" : "preparing"
            try await Task.sleep(nanoseconds: 200_000_000)
            var frame = try await readSettledFrame()
            if !jumpedToBoundary {
                // Seeking, probing and returning share the existing preparation
                // budget. A visual guess by itself cannot start composition.
                let preparationStarted = ProcessInfo.processInfo.systemUptime
                var preparationWheels = 0
                func remainingPreparationTime() throws -> TimeInterval {
                    let remaining = CaptureTopPreparation.maximumDuration - (ProcessInfo.processInfo.systemUptime - preparationStarted)
                    guard remaining > 0 else {
                        throw CaptureFailure("Could not verify the \(boundaryName) of this page within the preparation limit. No scrolling image was captured.")
                    }
                    return remaining
                }
                func preparationStep(towardStart: Bool, pixels: Int, settle: Bool = false) async throws -> ScrollCaptureFrame? {
                    guard try await performScroll({
                        if towardStart {
                            if traversal.preparesUp { try target.scrollUpTowardTop(pixels: pixels) }
                            else { try target.scrollDownTowardBottom(pixels: pixels) }
                        } else {
                            if traversal.capturesUp { try target.scrollUp(pixels: pixels) }
                            else { try target.scrollDown(pixels: pixels) }
                        }
                    }, beforeAttempt: {
                        _ = try remainingPreparationTime()
                        guard preparationWheels < CaptureTopPreparation.maximumAttempts else {
                            throw CaptureFailure("Could not verify the \(boundaryName) of this page within the preparation limit. No scrolling image was captured.")
                        }
                        preparationWheels += 1
                        self.startPreparationAttempts = preparationWheels
                    }) else { return nil }
                    try await Task.sleep(nanoseconds: 180_000_000)
                    let remaining = try remainingPreparationTime()
                    let observed = settle
                        ? try await readSettledFrame(before: Date().addingTimeInterval(remaining))
                        : try await readFrame(timeout: min(8, remaining))
                    _ = try remainingPreparationTime()
                    return observed
                }
                func seekBoundary(from initial: ScrollCaptureFrame) async throws -> CaptureTopPreparation.Result<ScrollCaptureFrame> {
                    try await CaptureTopPreparation.prepare(initial: initial,
                        shouldStop: { self.finishRequested },
                        elapsed: { ProcessInfo.processInfo.systemUptime },
                        advance: { try await preparationStep(towardStart: true,
                            pixels: min(2_000, max(400, Int(target.sourceRect.height)))) },
                        atBoundary: { traversal.progress(towardEnd: target.nativeVerticalScrollFraction()).map({ $0 <= 0.001 }) == true },
                        stable: { previous, next in
                            await Task.detached(priority: .userInitiated) {
                                CaptureEndpointContinuity.stationary(from: previous, to: next)
                            }.value
                        })
                }
                let prepared = try await seekBoundary(from: frame)
                frame = prepared.frame
                var evidence = prepared.evidence
                startPreparationEvidence = String(describing: evidence)
                if evidence == .inferred {
                    startPreparationEvidence = "verifyingVisualBoundary"
                    let reference = frame
                    var verifiedBody: CGRect?
                    var probeMovement: CaptureEndpointContinuity.Movement?
                    var awayFrame: ScrollCaptureFrame?
                    boundaryVerification["stage"] = "probe"
                    boundaryVerification["remainingSeconds"] = String(try remainingPreparationTime())
                    let restored = try await CaptureBoundaryVerification.verify(reference: reference,
                        shouldStop: { self.finishRequested },
                        probeAway: {
                            try await preparationStep(towardStart: false,
                                pixels: min(120, max(20, Int(target.sourceRect.height) / 10)), settle: true)
                        },
                        movementVerified: { boundary, away in
                            let observation = await Task.detached(priority: .userInitiated) {
                                CaptureEndpointContinuity.observe(from: boundary, to: away,
                                                                  captureUpward: traversal.capturesUp)
                            }.value
                            probeMovement = observation.movement
                            for (name, value) in observation.diagnostic {
                                boundaryVerification["probe_" + name] = value
                            }
                            awayFrame = away
                            verifiedBody = probeMovement?.verifiedContentRect
                            boundaryVerification["probeRows"] = probeMovement.map { String($0.rows) } ?? "unverified"
                            boundaryVerification["stage"] = verifiedBody == nil ? "probe_not_aligned" : "return"
                            if let verifiedBody { boundaryVerification["body"] = "\(verifiedBody.minX),\(verifiedBody.minY),\(verifiedBody.width),\(verifiedBody.height)" }
                            return verifiedBody != nil
                        },
                        returnToBoundary: { away in
                            let returned = try await seekBoundary(from: away)
                            boundaryVerification["returnEvidence"] = String(describing: returned.evidence)
                            guard returned.evidence == .observed || returned.evidence == .inferred else { return nil }
                            return try await readSettledFrame(before: Date().addingTimeInterval(try remainingPreparationTime()))
                        },
                        referenceRestored: { boundary, returned in
                            guard let body = verifiedBody, let probeMovement, let awayFrame else { return false }
                            let exact = await Task.detached(priority: .userInitiated) {
                                CaptureRollbackContinuity.matchesContent(boundary, returned, rect: body)
                            }.value
                            boundaryVerification["exactReturn"] = String(exact)
                            if exact {
                                boundaryVerification["stage"] = "verified"
                                boundaryVerification["proof"] = "exact_return"
                                return true
                            }
                            // Rasterization and lazy layout can change pixels at
                            // an endpoint. Measure the inverse movement instead
                            // of treating an identical bitmap as the position.
                            // seekBoundary must still infer stability under
                            // repeated delivered seek requests (or observe the
                            // native endpoint). Visual evidence stays inferred;
                            // a short, unrelated or ambiguous return is rejected.
                            let reverse = await Task.detached(priority: .userInitiated) {
                                CaptureEndpointContinuity.measure(from: awayFrame, to: returned,
                                                                  captureUpward: !traversal.capturesUp)
                            }.value
                            boundaryVerification["returnRows"] = reverse.map { String($0.rows) } ?? "unverified"
                            let matched = reverse.map { $0.rows >= probeMovement.rows } ?? false
                            if matched {
                                verifiedBody = reverse?.verifiedContentRect
                                boundaryVerification["proof"] = "dense_reverse_return"
                            }
                            boundaryVerification["stage"] = matched ? "verified" : "content_return_mismatch"
                            return matched
                        })
                    guard let restored else {
                        if finishRequested { cancel(); return }
                        throw CaptureFailure("Could not verify the \(boundaryName) of the selected area. Select only the moving page content and try again.")
                    }
                    frame = restored
                    boundaryContentRect = verifiedBody
                    evidence = .verifiedVisual
                    startPreparationEvidence = "verifiedVisual"
                }
                guard CaptureTraversal.startReached(preparationEvidence: evidence) else {
                    if evidence == .stopped { cancel(); return }
                    throw CaptureFailure("Could not reach the \(boundaryName) of this page. No scrolling image was captured.")
                }
                _ = try remainingPreparationTime()
                startConfirmed = evidence == .observed
            }
            guard token == session, !Task.isCancelled else { return }
            // Keep the endpoint frame which passed the proof above. Every later
            // observation retains the ordinary identity and overlap checks.
            var policy = AutoScrollPolicy(limits: .wholePage)
            var decision = policy.decide(.start(viewportHeight: Int(target.sourceRect.height)))
            capturePhase = "scrolling"
            captureLoop: while token == session, !Task.isCancelled {
                var observedOutcome: (ScrollStitcher.AppendResult, Int, Int)?
                if finishRequested { decision = policy.decide(.stop) }
                else if Date().timeIntervalSince(started) >= AutoScrollPolicy.Limits.wholePage.duration {
                    decision = policy.decide(.tick(elapsed: Date().timeIntervalSince(started)))
                }
                switch decision {
                case .finish(let reason, _):
                    captureOutcome = reason == .reachedEnd ? (startConfirmed ? "end_observed" : "end_inferred") : reason == .userStopped ? "stopped_early" : reason == .unverifiedEnd ? "end_unverified" : reason == .inferredEnd ? "end_inferred" : "partial"
                    switch reason {
                    case .reachedEnd: finalMessage = startConfirmed ? "Your scrolling screenshot is ready." : "Your scrolling screenshot is ready. Check the preview: the starting edge was verified visually."
                    case .userStopped: finalMessage = "Stopped early. This capture contains the accepted portion."
                    case .timeLimit: finalMessage = "Two-minute limit reached. This capture contains the accepted portion."
                    case .frameLimit, .pixelLimit: finalMessage = "Capture limit reached. This capture contains the accepted portion."
                    case .pageDidNotAdvance: finalMessage = "This page stopped advancing before the end. This capture contains the accepted portion."
                    case .inferredEnd: finalMessage = "Scrolling stopped. Check the preview: the complete page could not be confirmed."
                    case .unverifiedEnd:
                        throw CaptureFailure("The selected area did not scroll. Choose the scrollable page or a custom area, then try again.")
                    case .unstableContent(let reason): finalMessage = "\(reason) This capture contains the accepted portion."
                    }
                    break captureLoop
                case .abort:
                    cancel(); return
                case .scrollDown(let pixels, let settle), .checkEnd(let pixels, let settle):
                    if finishRequested { continue }
                    guard target.isCurrent() else { throw AutoScrollTarget.Failure.contentChanged }
                    guard try await performScroll({
                        if traversal.capturesUp { try target.scrollUp(pixels: pixels) }
                        else { try target.scrollDown(pixels: pixels) }
                    }) else { continue }
                    policy.recordEffectiveScrollStep(target.lastScrollMagnitude)
                    try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                    if finishRequested { continue }
                    observedOutcome = try await observeAfterScroll()
                case .recoverAndScrollDown(let rollback, let pixels, let settle):
                    if finishRequested { continue }
                    guard target.isCurrent() else { throw AutoScrollTarget.Failure.contentChanged }
                    guard let acceptedReference else { throw CaptureFailure("The accepted capture reference is unavailable.") }
                    let contentRect = stitcher.verifiedContentRect ?? boundaryContentRect
                    rollbackVerification = ["stage": "returning", "requestedPixels": String(rollback)]
                    let restored = try await CaptureRollbackContinuity.resumeIfRestored(reference: acceptedReference,
                        contentRect: contentRect,
                        rollback: {
                            guard try await performScroll({
                                if traversal.capturesUp { try target.scrollDown(pixels: rollback) }
                                else { try target.scrollUp(pixels: rollback) }
                            }) else { return false }
                            try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                            return token == session && !Task.isCancelled && !finishRequested
                        },
                        observe: {
                            let returned = try await readSettledFrame()
                            let exact = await Task.detached(priority: .userInitiated) {
                                contentRect.map { CaptureRollbackContinuity.matchesContent(acceptedReference, returned, rect: $0) }
                                    ?? CaptureRollbackContinuity.matchesReference(acceptedReference, returned)
                            }.value
                            rollbackVerification["exactReturn"] = String(exact)
                            return returned
                        },
                        resume: { try await performScroll({
                            if traversal.capturesUp { try target.scrollUp(pixels: pixels) }
                            else { try target.scrollDown(pixels: pixels) }
                        }) })
                    rollbackVerification["positionRestored"] = String(restored)
                    rollbackVerification["stage"] = restored ? "resumed" : "position_mismatch"
                    guard restored else {
                        if finishRequested { continue }
                        throw CaptureFailure("The page did not return to the last captured position.")
                    }
                    policy.recordEffectiveScrollStep(target.lastScrollMagnitude)
                    try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
                    if finishRequested { continue }
                    observedOutcome = try await observeAfterScroll()
                case .captureFirstFrame, .continueCapture: break
                }
                guard token == session, !Task.isCancelled else { return }
                guard target.isCurrent() else { throw AutoScrollTarget.Failure.contentChanged }
                let outcome: (ScrollStitcher.AppendResult, Int, Int)
                if let observedOutcome { outcome = observedOutcome }
                else {
                    let observationFrame = frame
                    outcome = await Task.detached(priority: .userInitiated) {
                        (stitcher.append(observationFrame), stitcher.width, stitcher.height)
                    }.value
                    if case .first = outcome.0 {
                        acceptedReference = observationFrame
                        recordProof(observationFrame, label: "reference")
                    }
                    if case .appended = outcome.0 { acceptedReference = observationFrame }
                }
                guard token == session, !Task.isCancelled else { return }
                acceptedCaptureFrames = stitcher.frameCount
                lastStitchResult = String(describing: outcome.0)
                if case .rejected(let reason) = outcome.0 {
                    lastStitchRejection = reason
                    rejectedAlignment = stitcher.lastAlignment
                }
                capturedSize = "\(outcome.1) × \(outcome.2) px"
                message = "Scrolling automatically. Stop to finish early."
                let observation: AutoScrollPolicy.StitchOutcome
                switch outcome.0 {
                case .first: observation = .first
                case .appended: observation = .appended
                case .unchanged: observation = .unchanged
                case .rejected(let reason): observation = .rejected(reason); message = "Adjusting the scroll step…"
                case .limitReached: observation = .limitReached
                }
                decision = policy.decide(.observation(observation, outputPixels: outcome.1 * outcome.2, scrollbarPosition: traversal.progress(towardEnd: target.nativeVerticalScrollFraction())))
            }
        } catch {
            guard token == session, !Task.isCancelled else { return }
            let targetChanged: Bool
            if let failure = error as? AutoScrollTarget.Failure {
                switch failure {
                case .applicationChanged, .windowChanged, .contentChanged, .displayUnavailable: targetChanged = true
                default: targetChanged = false
                }
            } else { targetChanged = false }
            lastTargetValidation = target.lastValidationIssue
            if targetChanged, !finishRequested {
                cancel(); showError("Capture cancelled because the page or window changed. Switch back to the page and try again."); return
            }
            if captureOutcome != "end_unverified" { captureOutcome = finishRequested ? "stopped_early" : "partial" }
            finalMessage = stitcher.frameCount == 0 ? error.localizedDescription :
                finishRequested ? "Stopped early. This capture contains the accepted portion." :
                "\(error.localizedDescription) This capture contains the accepted portion."
        }
        guard token == session, !Task.isCancelled else { return }
        if captureOutcome == "end_unverified" {
            if target.isCurrent() { target.restoreInitialScrollPositionIfSupported() }
            task = nil; controls?.orderOut(nil); controls = nil; activeAutoTarget = nil
            restoreWindows(); showError("The selected area did not scroll. Choose the scrollable page or a custom area, then try again.")
            return
        }
        if target.isCurrent() { target.restoreInitialScrollPositionIfSupported() }
        target.restorePointerIfUnmoved()
        activeAutoTarget = nil
        await presentCapture(stitcher, message: finalMessage, token: token)
    }

    nonisolated static func appearsStable(_ previous: ScrollCaptureFrame, _ current: ScrollCaptureFrame) -> Bool {
        guard previous.width == current.width, previous.height == current.height else { return false }
        var different = 0, sampled = 0
        // A caret or small animation must not keep a stationary top alive forever.
        for index in stride(from: 0, to: previous.pixels.count, by: 28) {
            sampled += 1
            if (0..<3).contains(where: { abs(Int(previous.pixels[index + $0]) - Int(current.pixels[index + $0])) > 12 }) { different += 1 }
        }
        return sampled > 0 && Double(different) / Double(sampled) < 0.001
    }

    private func presentCapture(_ stitcher: some ScrollImageAssembler, message finalMessage: String, token: UUID) async {
        capturePhase = "finishing"
        let imageWorker = Task.detached(priority: .userInitiated) { stitcher.image() }
        let image = await withTaskCancellationHandler(operation: { await imageWorker.value },
                                                       onCancel: { imageWorker.cancel() })
        guard token == session, !Task.isCancelled else { return }
        guard let image else {
            task = nil; controls?.orderOut(nil); controls = nil; restoreWindows(); capturePhase = "failed"
            showError(finalMessage.isEmpty ? "No image was captured." : finalMessage); return
        }
        message = copyWhenDone ? "Preparing to copy…" : "Preparing preview…"
        let encodingCancellation = CapturePNGEncoder.Cancellation()
        let encodingWorker = Task.detached(priority: .userInitiated) {
            CapturePNGEncoder.encode(image, cancellation: encodingCancellation)
        }
        let png = await withTaskCancellationHandler(operation: { await encodingWorker.value }, onCancel: {
            encodingCancellation.cancel(); encodingWorker.cancel()
        })
        guard token == session, !Task.isCancelled else { return }
        guard let png else {
            task = nil; controls?.orderOut(nil); controls = nil; restoreWindows()
            showError("The scrolling image could not be encoded. Check available memory and disk space.")
            return
        }
        task = nil; controls?.orderOut(nil); controls = nil; restoreWindows()
        resultPNG = png; result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        capturedSize = "\(image.width) × \(image.height) px"
        imageRevision &+= 1
        message = finalMessage.isEmpty ? "Your scrolling screenshot is ready." : finalMessage
        captureDetails = message
        capturePhase = "ready"
        presentResult()
    }

    nonisolated private static func frame(from image: CGImage) throws -> ScrollCaptureFrame {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 8_000_000 else { throw CaptureFailure("Choose a smaller area.") }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // CGContext's first memory row is the image's top row for this unflipped draw.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw CaptureFailure("The image could not be read.") }
        return try ScrollCaptureFrame(width: width, height: height, pixels: pixels)
    }

    nonisolated private static func boundedCapture<Value>(timeout: TimeInterval = 8, _ begin: @escaping (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let completion = CaptureCompletion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                guard !Task.isCancelled else { completion.resolve(.failure(CancellationError())); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, min(8, timeout))) { completion.resolve(.failure(CaptureTimeout())) }
                begin { completion.resolve($0) }
            }
        } onCancel: { completion.resolve(.failure(CancellationError())) }
    }

    func finish() { finishRequested = true; capturePhase = "finishing"; message = "Finishing capture…" }

    func cancel() {
        let returnToPage = isSelecting && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let originalApplication = previousApplication
        completeScopeSelection(.failure(CancellationError()))
        session = UUID()
        capturePhase = "cancelled"
        captureOutcome = "cancelled"
        task?.cancel(); task = nil
        activeAutoTarget?.restoreInitialScrollPositionIfSupported()
        activeAutoTarget?.restorePointerIfUnmoved(); activeAutoTarget = nil
        closeSelection()
        controls?.orderOut(nil); controls = nil
        restoreWindows()
        if returnToPage, let originalApplication, !originalApplication.isTerminated {
            NSApp.yieldActivation(to: originalApplication)
            originalApplication.activate(options: [])
        }
    }

    private func closeSelection() {
        selectionWindows.forEach { $0.orderOut(nil) }
        selectionWindows.removeAll()
        isSelecting = false
    }

    private func restoreWindows() {
        hiddenWindows.forEach { $0.orderFront(nil) }
        hiddenWindows.removeAll()
    }

    private func showControls(on screen: NSScreen, selection: CGRect, avoiding: CGPoint? = nil) {
        let size = ScrollCaptureControls.preferredSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollCaptureControls(model: self))
        let area = selection.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let candidates = [
            CGPoint(x: area.maxX - size.width - 14, y: area.minY + 14),
            CGPoint(x: area.minX + 14, y: area.minY + 14),
            CGPoint(x: area.maxX - size.width - 14, y: area.maxY - size.height - 14),
            CGPoint(x: area.minX + 14, y: area.maxY - size.height - 14)
        ].map { CGPoint(x: max(screen.visibleFrame.minX, min($0.x, screen.visibleFrame.maxX - size.width)),
                        y: max(screen.visibleFrame.minY, min($0.y, screen.visibleFrame.maxY - size.height))) }
        var appKitPoint: CGPoint?
        if let avoiding, let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            let bounds = CGDisplayBounds(id)
            appKitPoint = CGPoint(x: screen.frame.minX + avoiding.x - bounds.minX,
                                  y: screen.frame.maxY - (avoiding.y - bounds.minY))
        }
        let origin = candidates.first { point in
            guard let appKitPoint else { return true }
            return !CGRect(origin: point, size: size).insetBy(dx: -18, dy: -18).contains(appKitPoint)
        } ?? candidates[0]
        panel.setFrameOrigin(origin)
        controls = panel
        panel.orderFrontRegardless()
    }

    private func showPermission() {
        if let permissionWindow {
            NSApp.activate(ignoringOtherApps: true); permissionWindow.makeKeyAndOrderFront(nil); return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ScrollCapturePermission.preferredSize.width, height: ScrollCapturePermission.preferredSize.height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Page screenshot · Dial"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollCapturePermission(model: self))
        window.center(); permissionWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    func requestPermission() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    private func retryApplication() -> NSRunningApplication? {
        guard let original = previousApplication, !original.isTerminated,
              let identifier = original.bundleIdentifier else { return nil }
        let matching = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated }
        guard matching.count == 1, matching[0].processIdentifier == original.processIdentifier else { return nil }
        return original
    }

    func retryAfterPermission() {
        guard let original = retryApplication() else {
            showError("The original app is no longer available. Start a new capture from the page you want."); return
        }
        start(copyWhenDone: copyWhenDone, automatic: automatic, application: original, screenshotOnly: singleShot)
    }

    private func dismissCaptureError() {
        let alert = captureErrorAlert
        captureErrorAlert = nil
        captureErrorActions = nil
        alert?.window.delegate = nil
        alert?.window.close()
    }

    private func showError(_ text: String) {
        invalidateImageEdit()
        dismissCopyFeedback()
        dismissCaptureError()
        capturePhase = "failed"; captureOutcome = "failed"
        message = text; captureDetails = text; result = nil; resultPNG = nil; copied = false
        preview?.orderOut(nil)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = singleShot ? "Couldn’t take the screenshot" : "Couldn’t capture the page"
        alert.informativeText = text
        alert.showsHelp = false
        alert.showsSuppressionButton = false
        let canRetry = retryApplication() != nil
        if canRetry { alert.addButton(withTitle: "Try Again").keyEquivalent = "\r" }
        alert.addButton(withTitle: "Dismiss").keyEquivalent = "\u{1b}"
        // Populate the native alert before exposing its window. Bypassing this
        // layout leaves template controls, blank buttons, and clipped text.
        alert.layout()
        let actions = CaptureAlertActions { [weak self, weak alert] retry in
            guard let self, let alert, self.captureErrorAlert === alert else { return }
            self.dismissCaptureError()
            if retry { self.retryAfterPermission() }
        }
        for (index, button) in alert.buttons.enumerated() {
            button.tag = canRetry && index == 0 ? 1 : 0
            button.target = actions
            button.action = #selector(CaptureAlertActions.choose(_:))
        }
        alert.window.isReleasedWhenClosed = false
        alert.window.delegate = actions
        captureErrorActions = actions
        captureErrorAlert = alert
        alert.window.center()
        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeKeyAndOrderFront(nil)
        // No runModal: status, cancellation and the next capture remain usable.
    }

    private func showPreview() {
        dismissCopyFeedback()
        guard result != nil else { return }
        if preview == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ScrollCapturePreview.preferredSize.width, height: ScrollCapturePreview.preferredSize.height), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Page screenshot · Dial"
            window.contentMinSize = ScrollCapturePreview.minimumSize
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: ScrollCapturePreview(model: self))
            window.center(); preview = window
        }
        preview?.title = singleShot ? "Screenshot · Dial" : "Page screenshot · Dial"
        NSApp.activate(ignoringOtherApps: true); preview?.makeKeyAndOrderFront(nil)
    }

    private func presentResult() {
        if copyWhenDone {
            copyImage()
            if copied { showCopyFeedback(); return }
            message = "Could not copy the screenshot. Use Copy to try again."
        }
        showPreview()
    }

    private func dismissCopyFeedback(releaseResult: Bool = false) {
        copyFeedbackDismissal?.cancel(); copyFeedbackDismissal = nil
        copyFeedback?.orderOut(nil); copyFeedback = nil
        if releaseResult, preview?.isVisible != true {
            invalidateImageEdit()
            result = nil; resultPNG = nil
        }
    }

    private func showCopyFeedback() {
        dismissCopyFeedback()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = ScrollCaptureCopyFeedback.preferredSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let detail: String?
        switch captureOutcome {
        case "end_observed", "manual_finished", "snapshot": detail = nil
        case "stopped_early": detail = "Stopped early"
        case "end_inferred": detail = "Page boundary unconfirmed"
        case "end_unverified": detail = "Visible area only"
        default: detail = "Partial capture · Show to review"
        }
        panel.contentView = NSHostingView(rootView: ScrollCaptureCopyFeedback(detail: detail, onShow: { [weak self] in self?.showPreview() }, onDismiss: { [weak self] in self?.dismissCopyFeedback(releaseResult: true) }))
        panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - size.width - 20, y: screen.visibleFrame.maxY - size.height - 20))
        copyFeedback = panel
        panel.orderFrontRegardless()
        copyFeedbackDismissal = Task { @MainActor [weak self, weak panel] in
            do { try await Task.sleep(nanoseconds: detail == nil ? 3_000_000_000 : 6_000_000_000) }
            catch { return }
            guard let self, let panel, self.copyFeedback === panel else { return }
            self.dismissCopyFeedback(releaseResult: true)
        }
    }

    func copyImage() {
        guard let data = resultPNG else { return }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setData(data, forType: .png)
    }

    private func invalidateImageEdit() {
        imageEditGeneration = UUID()
        imageEditTask?.cancel(); imageEditTask = nil; isEditingImage = false
    }

    func cancelImageEdit() {
        invalidateImageEdit()
    }

    func applyEdits(crop: CGRect?, annotations: [CaptureImageAnnotation]) {
        guard !isEditingImage, task == nil, let original = result,
              let source = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let generation = UUID()
        imageEditGeneration = generation; isEditingImage = true
        imageEditTask = Task { @MainActor [weak self] in
            do {
                let renderTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let image = try CaptureImageRenderer.render(source: source, crop: crop, annotations: annotations)
                    try Task.checkCancellation()
                    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        throw CaptureFailure("The edited image could not be prepared.")
                    }
                    return (image, png)
                }
                let edited = try await withTaskCancellationHandler {
                    try await renderTask.value
                } onCancel: { renderTask.cancel() }
                guard let self, !Task.isCancelled, self.imageEditGeneration == generation,
                      self.result === original else { return }
                self.resultPNG = edited.1
                self.result = NSImage(cgImage: edited.0, size: NSSize(width: edited.0.width, height: edited.0.height))
                self.capturedSize = "\(edited.0.width) × \(edited.0.height) px"
                self.copied = false; self.message = "Edits applied"
                self.imageRevision &+= 1
                self.imageEditTask = nil; self.isEditingImage = false
            } catch {
                guard let self, !Task.isCancelled, self.imageEditGeneration == generation else { return }
                self.message = "Could not apply edits. Try a smaller selection."
                self.imageEditTask = nil; self.isEditingImage = false
            }
        }
    }

    func save() {
        guard let data = resultPNG else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "\(singleShot ? "Screenshot" : "Scrolling Screenshot") \(formatter.string(from: Date())).png"
        guard let preview else { return }
        panel.beginSheetModal(for: preview) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); self.message = "Saved \(url.lastPathComponent)" }
            catch { self.message = "Could not save: \(error.localizedDescription)" }
        }
    }

    func windowWillClose(_ notification: Notification) { invalidateImageEdit(); result = nil; resultPNG = nil }
}

private struct CaptureFailure: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}

private struct CaptureTimeout: LocalizedError {
    var errorDescription: String? { "Screen capture timed out. Try again." }
}

/// Cancellation, a timeout and an OS callback may race. Resume exactly once.
final class CaptureCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var complete = false
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if complete { let result = pending!; pending = nil; lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !complete else { lock.unlock(); return }
        complete = true
        if let continuation { self.continuation = nil; lock.unlock(); continuation.resume(with: result) }
        else { pending = result; lock.unlock() }
    }
}

private final class CaptureSelectionWindow: NSWindow {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

private final class CaptureSelectionView: NSView {
    var completed: (CGRect) -> Void = { _ in }
    private var anchor: NSPoint?
    private var selection = CGRect.zero
    private var maximumExcursion: CGFloat = 0
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { anchor = convert(event.locationInWindow, from: nil); maximumExcursion = 0; selection = .zero; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let end = convert(event.locationInWindow, from: nil)
        maximumExcursion = max(maximumExcursion, hypot(end.x - anchor.x, end.y - anchor.y))
        selection = CGRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y), width: abs(anchor.x - end.x), height: abs(anchor.y - end.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if let anchor, let selected = CaptureSelectionGeometry.resolve(anchor: anchor, end: convert(event.locationInWindow, from: nil), maximumExcursion: maximumExcursion, bounds: bounds) {
            completed(selected)
        }
        self.anchor = nil
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { (window as? CaptureSelectionWindow)?.onCancel() } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.append(NSBezierPath(rect: selection)); shade.windingRule = .evenOdd }
        shade.fill()
        if !selection.isEmpty { NSColor.controlAccentColor.setStroke(); let outline = NSBezierPath(rect: selection); outline.lineWidth = 2; outline.stroke() }
        let hintAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white]
        ("Click for full display · Drag to select page content" as NSString).draw(at: NSPoint(x: 30, y: bounds.height - 65), withAttributes: hintAttributes)
        ("Leave out fixed headers and sidebars · Esc to cancel" as NSString).draw(at: NSPoint(x: 30, y: bounds.height - 88), withAttributes: hintAttributes)
    }
}

/// Machine-readable commands never start capture in this headless process.
enum CaptureCommand {
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard arguments.first == "--capture" else { return nil }
        var payload: [String: Any] = ["ok": true]
        let applicationIdentifier: String?
        if arguments.count == 4, ["scroll", "copy-scroll", "snapshot", "copy-snapshot"].contains(arguments[1]), arguments[2] == "--application",
           !arguments[3].isEmpty, arguments[3].count <= 255,
           arguments[3].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) {
            applicationIdentifier = arguments[3]
        } else { applicationIdentifier = nil }
        guard (arguments.count == 2 || applicationIdentifier != nil), arguments.count >= 2,
              ["status", "scroll", "copy-scroll", "snapshot", "copy-snapshot", "manual-scroll", "manual-copy-scroll", "confirm-page", "confirm-window", "confirm-screen", "stop", "cancel", "help"].contains(arguments[1]) else {
            payload = ["ok": false, "error": "Use --capture status|scroll|copy-scroll|snapshot|copy-snapshot|manual-scroll|manual-copy-scroll|confirm-page|confirm-window|confirm-screen|stop|cancel|help; scroll/copy-scroll/snapshot/copy-snapshot optionally accept --application bundle.identifier"]
            emit(payload); return 2
        }
        switch arguments[1] {
        case "status":
            payload["screenCaptureAllowed"] = CGPreflightScreenCaptureAccess()
            payload["scope"] = "permission and running-app metadata only; no capture"
            let reports = CaptureStatusProbe().readReports()
            payload["runningAppResponseReceived"] = !reports.isEmpty
            payload["ambiguousRunningApps"] = reports.count > 1
            if reports.count == 1 { payload["runningAppReport"] = reports[0] }
        case "help":
            payload["commands"] = ["status", "scroll", "copy-scroll", "snapshot", "copy-snapshot", "manual-scroll", "manual-copy-scroll", "confirm-page", "confirm-window", "confirm-screen", "stop", "cancel"]
            payload["applicationOption"] = "scroll/copy-scroll/snapshot/copy-snapshot accept --application bundle.identifier to activate and capture one running app explicitly."
            payload["workflow"] = "Hover to highlight a page or window on any monitor. Left click starts capture; right click or Escape cancels. Drag to select a custom area. scroll/copy-scroll moves to the top and captures downward automatically; snapshot/copy-snapshot captures one image. Copy commands copy PNG. confirm-page/window/screen confirms that scope in an active picker without UI steps. Stop keeps the accepted portion; cancel discards. Manual scroll commands retain manual scrolling and Done."
        default:
            let reports = CaptureStatusProbe().readReports()
            guard reports.count == 1, let pid = reports[0]["respondingPID"] as? NSNumber,
                  let session = reports[0]["sessionID"] as? String else {
                emit(["ok": false, "error": reports.isEmpty ? "No reply from this Dial GUI. Keep Dial running and try again." : "Multiple matching Dial GUIs replied. Close the duplicate before capture.", "deliveryVerified": false]); return 1
            }
            let operation: String
            switch arguments[1] {
            case "copy-scroll": operation = "copy"
            case "snapshot", "copy-snapshot": operation = arguments[1]
            case "manual-scroll": operation = "manual"
            case "manual-copy-scroll": operation = "manual-copy"
            case "stop", "cancel", "confirm-page", "confirm-window", "confirm-screen": operation = arguments[1]
            default: operation = "preview"
            }
            var request: [String: Any] = ["targetPID": pid, "sessionID": session]
            if let applicationIdentifier { request["applicationIdentifier"] = applicationIdentifier }
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("io.github.eroyun.dial.capture.scroll"), object: operation, userInfo: request, deliverImmediately: true)
            payload["requestSent"] = true; payload["deliveryVerified"] = false; payload["targetPID"] = pid
            if ["scroll", "copy-scroll", "snapshot", "copy-snapshot", "manual-scroll", "manual-copy-scroll"].contains(arguments[1]) { payload["openRequestSent"] = true }
        }
        emit(payload); return 0
    }
    private static func emit(_ payload: [String: Any]) {
        if let bytes = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) { print(text) }
    }
}

/// A fresh local metadata request. A missing reply means unknown, not stopped.
final class CaptureStatusProbe: NSObject {
    private var reports: [Int32: [String: Any]] = [:]
    private let lock = NSLock()
    private let nonce = UUID().uuidString
    private let acceptsProcess: (Int32) -> Bool
    init(acceptsProcess: ((Int32) -> Bool)? = nil) {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath().path
        self.acceptsProcess = acceptsProcess ?? { pid in
            guard let executable else { return false }
            return NSRunningApplication(processIdentifier: pid)?.executableURL?.resolvingSymlinksInPath().path == executable
        }
        super.init()
    }
    func readReports() -> [[String: Any]] {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(received(_:)), name: Notification.Name("io.github.eroyun.dial.capture.scroll.reply." + nonce), object: nil)
        defer { center.removeObserver(self) }
        center.postNotificationName(Notification.Name("io.github.eroyun.dial.capture.scroll.status"), object: nonce, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(0.8)
        // Collect through the bounded response window so two GUI instances cannot
        // race to masquerade as the only one. Reading status never starts capture.
        while Date() < deadline { RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05))) }
        lock.lock(); defer { lock.unlock() }
        return reports.keys.sorted().compactMap { reports[$0] }
    }
    @objc private func received(_ note: Notification) {
        guard let info = note.userInfo as? [String: Any], let pid = info["respondingPID"] as? NSNumber,
              pid.int64Value > 0, pid.int64Value <= Int32.max, acceptsProcess(pid.int32Value),
              let session = info["sessionID"] as? String, UUID(uuidString: session) != nil,
              JSONSerialization.isValidJSONObject(info),
              let bytes = try? JSONSerialization.data(withJSONObject: info), bytes.count <= 8_192 else { return }
        lock.lock(); defer { lock.unlock() }
        reports[pid.int32Value] = info
    }
}

/// Retain native button actions without blocking the main actor in runModal.
@MainActor
private final class CaptureAlertActions: NSObject, NSWindowDelegate {
    private let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    @objc func choose(_ sender: NSButton) { completion(sender.tag == 1) }
    func windowWillClose(_ notification: Notification) { completion(false) }
}
