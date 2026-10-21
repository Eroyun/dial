import AppKit

/// Right-clicking the menu-bar icon opens a short menu of switches, so they can be flipped
/// without opening the panel. Dial watches for right-clicks that land on its own status bar
/// window.
final class RightClickMenu {
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let window = event.window, window.className.contains("NSStatusBarWindow"),
                  let view = window.contentView else { return event }
            NSMenu.popUpContextMenu(self.menu(), with: event, for: view)
            return nil
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        if !Access.shared.granted {
            menu.addItem(Item("Set Up Keyboard Keys…") { Access.shared.ask() })
        }
        menu.addItem(Item("Open at Login", on: LoginItem.shared.enabled) { LoginItem.shared.set(!LoginItem.shared.enabled) })
        menu.addItem(.separator())
        let quit = Item("Quit Dial") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }
}

/// A menu item that runs a closure.
private final class Item: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, on: Bool? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let on { state = on ? .on : .off }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
