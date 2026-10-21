import CoreGraphics
import Foundation

@main
enum CaptureChatRegionTests {
    static func main() {
        let claude = "com.anthropic.claudefordesktop"
        let codex = "com.openai.codex"
        let window = CGRect(x: 100, y: 80, width: 1_200, height: 800)

        precondition(CaptureChatRegion.isSupportedApplication(claude))
        precondition(CaptureChatRegion.isSupportedApplication(codex))
        precondition(!CaptureChatRegion.isSupportedApplication("com.example.other"))
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: claude, role: "AXGroup", description: "Chat messages",
            title: nil, help: nil, identifier: nil
        ) == 1, "Exact Claude message-pane label is accepted")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: codex, role: "AXScrollArea", description: nil,
            title: "Conversation", help: nil, identifier: nil
        ) == 1, "Exact message-container labels are available to known chat apps")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: codex, role: "AXList", description: nil,
            title: nil, help: nil, identifier: "conversation.messages"
        ) == 0, "Unverified identifiers cannot select a pane")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: claude, role: "AXGroup", description: nil,
            title: "Conversation", help: nil, identifier: nil
        ) == 0, "Codex label is rejected in Claude")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: codex, role: "AXGroup", description: "Chat messages",
            title: nil, help: nil, identifier: nil
        ) == 0, "Claude label is rejected in Codex")

        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: "com.example.other", role: "AXGroup", description: "Chat messages",
            title: nil, help: nil, identifier: nil
        ) == 0, "Policy is limited to inventoried application identifiers")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: claude, role: "AXStaticText", description: "Chat messages",
            title: nil, help: nil, identifier: nil
        ) == 0, "Static text cannot nominate a region")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: claude, role: "AXTextArea", description: "Messages",
            title: nil, help: nil, identifier: nil
        ) == 0, "Composer text areas cannot nominate a region")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: claude, role: "AXGroup", description: "OpenAI Chat messages now",
            title: nil, help: nil, identifier: nil
        ) == 0, "Substring matches and user-authored text do not count")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: claude, role: "AXGroup", description: " Messages ",
            title: nil, help: nil, identifier: nil
        ) == 0, "Unverified generic labels and whitespace variants are rejected")
        precondition(CaptureChatRegion.labelStrength(
            bundleIdentifier: claude, role: "AXGroup", description: nil,
            title: nil, help: "Chat messages", identifier: nil
        ) == 0, "Help-only matches remain unverified")

        let pane = CGRect(x: 400, y: 120, width: 700, height: 690)
        let bottomOverlay = CGRect(x: 400, y: 650, width: 700, height: 160)
        precondition(CaptureChatRegion.excludingBottomOverlay(bottomOverlay, from: pane)
            == CGRect(x: 400, y: 120, width: 700, height: 530))
        precondition(CaptureChatRegion.excludingBottomOverlay(CGRect(x: 410, y: 650, width: 100, height: 160), from: pane) == pane,
            "An incidental narrow control cannot crop the full pane")
        let questionRail = CGRect(x: 430, y: 400, width: 640, height: 410)
        precondition(CaptureChatRegion.excludingBottomOverlay(questionRail, from: pane)
            == CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: 280),
            "A growing composer rail must be excluded as one region, including its question controls")
        let sidebar = CGRect(x: 100, y: 120, width: 250, height: 690)
        precondition(CaptureChatRegion.composerBranch(frame: sidebar, pane: pane) == .irrelevant,
            "A navigation branch cannot nominate a composer under the LCA crop policy")
        precondition(CaptureChatRegion.composerBranch(frame: questionRail, pane: pane) == .overlay(questionRail))
        precondition(CaptureChatRegion.composerBranch(frame: nil, pane: pane) == .unknown)
        precondition(CaptureChatRegion.composerBranch(frame: .zero, pane: pane) == .unknown)
        precondition(CaptureChatRegion.composerBranch(frame: CGRect(x: CGFloat.nan, y: 500, width: 700, height: 310), pane: pane) == .unknown,
            "Invalid geometry must not be mistaken for a proven off-pane branch")
        let edge = CaptureChatRegion.scrollPoint(in: pane)!
        precondition(pane.contains(edge) && edge.x == pane.maxX - 16 && edge.y == pane.midY,
            "The chat wheel point follows the pane edge rather than the click location")
        let translatedPane = pane.offsetBy(dx: -1_500, dy: 200)
        precondition(CaptureChatRegion.scrollPoint(in: translatedPane) == CGPoint(x: edge.x - 1_500, y: edge.y + 200))
        precondition(CaptureChatRegion.scrollPoint(in: .zero) == nil)
        precondition(CaptureChatRegion.scrollPoints(in: pane).allSatisfy(pane.contains),
            "Every alternate position must remain inside the same selected pane")
        for role in ["AXButton", "AXRadioButton", "AXTextArea", "AXComboBox"] {
            precondition(CaptureChatRegion.isInteractiveRole(role))
        }
        for role in ["AXGroup", "AXStaticText", "AXWebArea"] {
            precondition(!CaptureChatRegion.isInteractiveRole(role))
        }

        let pointer = CGPoint(x: 700, y: 500)
        precondition(CaptureChatRegion.selectedRect(
            candidates: [pane], windowBounds: window, pointer: pointer
        ) == pane, "A unique pane inside the window is selected")
        precondition(CaptureChatRegion.selectedRect(
            candidates: [pane, pane], windowBounds: window, pointer: pointer
        ) == pane, "Repeated identical geometry is deduplicated")

        let nested = CGRect(x: 420, y: 140, width: 660, height: 650)
        precondition(CaptureChatRegion.selectedRect(
            candidates: [pane, nested], windowBounds: window, pointer: pointer
        ) == nested, "Nested containers resolve to their innermost pane")

        let otherPane = CGRect(x: 150, y: 120, width: 200, height: 600)
        precondition(CaptureChatRegion.selectedRect(
            candidates: [pane, otherPane], windowBounds: window, pointer: pointer
        ) == nil, "Distinct candidate panes are ambiguous")
        precondition(CaptureChatRegion.selectedRect(
            candidates: [CGRect(x: 1_500, y: 120, width: 300, height: 500)],
            windowBounds: window, pointer: pointer
        ) == nil, "Off-window geometry is rejected")
        precondition(CaptureChatRegion.selectedRect(
            candidates: [CGRect(x: 0, y: -500, width: 400, height: 300)],
            windowBounds: window, pointer: pointer
        ) == nil, "A pane outside the owning window is rejected")
        precondition(CaptureChatRegion.selectedRect(
            candidates: [pane], windowBounds: window, pointer: CGPoint(x: 1_400, y: 500)
        ) == nil, "Pointer validation uses the actual owning window bounds")

        let partlyOutside = CGRect(x: 80, y: 60, width: 400, height: 400)
        precondition(CaptureChatRegion.selectedRect(
            candidates: [partlyOutside], windowBounds: window, pointer: pointer
        ) == CGRect(x: 100, y: 80, width: 380, height: 380), "Pane geometry is clipped to the window")

        let resizedWindow = CGRect(x: -300, y: 40, width: 900, height: 650)
        let resizedPane = CGRect(x: -200, y: 90, width: 700, height: 550)
        precondition(CaptureChatRegion.selectedRect(
            candidates: [resizedPane], windowBounds: resizedWindow, pointer: CGPoint(x: 0, y: 300)
        ) == resizedPane, "Policy follows resized and translated window geometry")

        precondition(CaptureChatRegion.excludesLookupBranch(bundleIdentifier: claude, role: "AXGroup",
            description: "Sidebar", frame: nil, pointer: pointer))
        precondition(!CaptureChatRegion.excludesLookupBranch(bundleIdentifier: codex, role: "AXGroup",
            description: "Sidebar", frame: nil, pointer: pointer))
        precondition(CaptureChatRegion.excludesLookupBranch(bundleIdentifier: codex, role: "AXList",
            description: nil, frame: CGRect(x: -400, y: 0, width: 100, height: 200), pointer: pointer))
        precondition(!CaptureChatRegion.excludesLookupBranch(bundleIdentifier: codex, role: "AXGroup",
            description: nil, frame: CGRect(x: -400, y: 0, width: 100, height: 200), pointer: pointer))
        for unknown in [nil, CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 100, height: 200)] as [CGRect?] {
            precondition(!CaptureChatRegion.excludesLookupBranch(bundleIdentifier: codex, role: "AXList",
                description: nil, frame: unknown, pointer: pointer))
        }
        print("Capture chat-region semantic and geometry policy checks passed")
    }
}
