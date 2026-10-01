import AppKit
import SwiftUI

/// Shows `content` in a popover below the view it is attached to, with a flat top edge
/// instead of SwiftUI's arrow. Clicking elsewhere or pressing Esc closes it.
struct Dropdown<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let onClose: () -> Void
    let content: () -> Content

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onClose = onClose
        if isPresented, coordinator.popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = NSHostingController(rootView: content())
            popover.delegate = coordinator
            // Not public API, so only used where it exists; without it the arrow simply stays.
            if popover.responds(to: Selector(("setShouldHideAnchor:"))) {
                popover.setValue(true, forKey: "shouldHideAnchor")
            }
            coordinator.popover = popover
            DispatchQueue.main.async { popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY) }
        } else if !isPresented, let popover = coordinator.popover {
            coordinator.popover = nil
            popover.close()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var onClose: () -> Void = {}

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            onClose()
        }
    }
}
