import CoreGraphics
import Foundation

/// Pure policy for resolving a labeled chat-message container to a safe window-local capture region.
/// Accessibility traversal is responsible for supplying labels from container nodes only.
enum CaptureChatRegion {
    private static let supportedApplications: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
    ]

    private static let containerRoles: Set<String> = [
        "AXGroup", "AXList", "AXOutline", "AXScrollArea", "AXTable", "AXContainer",
    ]

    private static let labelByApplication: [String: String] = [
        "com.anthropic.claudefordesktop": "Chat messages",
        "com.openai.codex": "Conversation",
    ]

    private static let minimumWidth: CGFloat = 120
    private static let minimumHeight: CGFloat = 100

    static func isSupportedApplication(_ bundleIdentifier: String) -> Bool {
        labelByApplication[bundleIdentifier] != nil
    }

    /// Returns 1 only for the verified exact label for that app on a container role.
    /// Help and identifier values remain unsupported until verified against the installed apps.
    static func labelStrength(
        bundleIdentifier: String,
        role: String,
        description: String?,
        title: String?,
        help: String?,
        identifier: String?
    ) -> Int {
        guard isSupportedApplication(bundleIdentifier), containerRoles.contains(role),
              let approvedLabel = labelByApplication[bundleIdentifier] else { return 0 }
        return description == approvedLabel || title == approvedLabel ? 1 : 0
    }

    /// Selects a unique, plausible pane after clipping it to its owning window.
    /// The pointer is required to be within the window, but may be over window chrome or controls.
    static func selectedRect(candidates: [CGRect], windowBounds: CGRect, pointer: CGPoint) -> CGRect? {
        guard finite(windowBounds), finite(pointer) else { return nil }
        let window = windowBounds.standardized
        guard window.width >= minimumWidth, window.height >= minimumHeight, window.contains(pointer) else { return nil }

        let clipped = candidates.compactMap { rect -> CGRect? in
            guard finite(rect) else { return nil }
            let result = rect.standardized.intersection(window)
            guard !result.isNull, !result.isEmpty,
                  result.width >= minimumWidth, result.height >= minimumHeight else { return nil }
            return result
        }
        // The same pane is often exposed by nested AX containers. Prefer the innermost geometry
        // when one clipped rectangle contains another; distinct, non-nested panes remain ambiguous.
        var unique: [CGRect] = []
        for rect in clipped where !unique.contains(rect) { unique.append(rect) }
        let innermost = unique.filter { outer in
            !unique.contains { inner in inner != outer && outer.contains(inner) }
        }
        guard innermost.count == 1 else { return nil }
        return innermost[0]
    }

    enum ComposerBranch: Equatable {
        case unknown
        case irrelevant
        case overlay(CGRect)
    }

    static func excludesLookupBranch(bundleIdentifier: String, role: String,
                                     description: String?, frame: CGRect?, pointer: CGPoint) -> Bool {
        if bundleIdentifier == "com.anthropic.claudefordesktop",
           ["AXGroup", "AXToolbar"].contains(role),
           ["Sidebar", "Artifacts", "Notifications", "Chat toolbar"].contains(description ?? "") { return true }
        guard isSupportedApplication(bundleIdentifier), ["AXList", "AXOutline"].contains(role),
              let frame, finite(frame), frame.width > 0, frame.height > 0 else { return false }
        return !frame.contains(pointer)
    }

    /// Classify the LCA sibling itself, which is the branch whose bounds the
    /// composer policy uses for every descendant control.
    static func composerBranch(frame: CGRect?, pane: CGRect) -> ComposerBranch {
        guard let frame, finite(frame), finite(pane),
              frame.width > 0, frame.height > 0 else { return .unknown }
        return excludingBottomOverlay(frame, from: pane) == pane ? .irrelevant : .overlay(frame)
    }

    /// Candidate positions stay inside the transcript and away from a clicked
    /// widget. The native target resolver still tests their actual AX hit paths.
    static func scrollPoints(in pane: CGRect) -> [CGPoint] {
        guard finite(pane), pane.width >= minimumWidth, pane.height >= minimumHeight else { return [] }
        return [CGPoint(x: pane.maxX - 16, y: pane.midY),
                CGPoint(x: pane.minX + 16, y: pane.midY),
                CGPoint(x: pane.maxX - 40, y: pane.midY),
                CGPoint(x: pane.minX + 40, y: pane.midY),
                CGPoint(x: pane.midX, y: pane.midY)]
    }

    static func scrollPoint(in pane: CGRect) -> CGPoint? { scrollPoints(in: pane).first }

    static func isInteractiveRole(_ role: String) -> Bool {
        ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox",
         "AXTextField", "AXTextArea", "AXSlider", "AXMenu", "AXMenuItem", "AXListBox"].contains(role)
    }

    /// A fixed sibling at the bottom may overlay the named scrolling region.
    /// Only trim a known composer branch centered on the pane at its bottom edge.
    static func excludingBottomOverlay(_ overlay: CGRect, from pane: CGRect) -> CGRect {
        guard finite(overlay), finite(pane), overlay.minY > pane.minY,
              overlay.minX <= pane.midX, overlay.maxX >= pane.midX,
              overlay.maxY >= pane.maxY - 1 else { return pane }
        return CGRect(x: pane.minX, y: pane.minY, width: pane.width,
                      height: min(pane.maxY, overlay.minY) - pane.minY)
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite
    }

    private static func finite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

}
