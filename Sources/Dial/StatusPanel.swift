import AppKit
import SwiftUI

/// The menu-bar icon and the glass panel under it. Dial owns the window instead of using
/// MenuBarExtra: that window kept a stale height when cards came and went, leaving see-through
/// bands around a square box.
final class StatusPanel: NSObject, NSWindowDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let displays: DisplayStore
    private let window = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private var outsideClicks: Any?
    private var closedAt = Date.distantPast
    private var size = CGSize.zero

    init(displays: DisplayStore, touch: TouchController) {
        self.displays = displays
        super.init()
        item.button?.image = NSImage(systemSymbolName: "dial.medium.fill", accessibilityDescription: "Dial")
        item.button?.target = self
        item.button?.action = #selector(toggle)

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }
        let content = Panel(displays: displays, touch: touch)
            .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] in self?.size = $0; self?.place() }
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [] // the panel is sized here, top edge fixed, not by the hosting view
        window.contentView = host
    }

    @objc private func toggle() {
        // The click that closes the panel by taking its focus must not open it again.
        if window.isVisible { close() } else if Date().timeIntervalSince(closedAt) > 0.2 { open() }
    }

    private func open() {
        place()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }
        item.button?.highlight(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
    }

    private func close() {
        guard window.isVisible else { return }
        closedAt = Date()
        displays.displays.forEach { $0.showingSizes = false }
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        item.button?.highlight(false)
        window.orderOut(nil)
    }

    /// Sizes the panel to its content and hangs it under the icon, kept on screen.
    private func place() {
        guard size.width > 0, size.height > 0, let button = item.button?.window else { return }
        let icon = button.frame
        var x = icon.minX
        if let screen = button.screen?.visibleFrame {
            x = max(screen.minX + 8, min(x, screen.maxX - size.width - 8))
        }
        window.setFrame(NSRect(x: x, y: icon.minY - 6 - size.height, width: size.width, height: size.height), display: true)
        window.invalidateShadow()
    }

    /// Clicking elsewhere in Dial closes the panel; its own size list taking focus does not.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [self] in
            if let key = NSApp.keyWindow, key == window || key.parent == window { return }
            close()
        }
    }
}

/// A borderless panel that takes the keyboard, so Esc and ⌘Q work in it.
private final class KeyPanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}
