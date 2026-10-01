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
            let host = NSHostingController(rootView: content())
            popover.contentViewController = host
            popover.contentSize = host.view.fittingSize
            popover.delegate = coordinator
            // Not public API, so only used where it exists; without it the arrow simply stays.
            if popover.responds(to: Selector(("setShouldHideAnchor:"))) {
                popover.setValue(true, forKey: "shouldHideAnchor")
            }
            coordinator.popover = popover
            // NSPopover centres itself on the rect it is shown from; a rect as wide as the popover,
            // starting at the view's left edge, lines the two left edges up like a dropdown.
            DispatchQueue.main.async {
                let width = max(popover.contentSize.width, view.bounds.width)
                let rect = NSRect(x: 0, y: view.bounds.minY, width: width, height: view.bounds.height)
                popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
            }
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
