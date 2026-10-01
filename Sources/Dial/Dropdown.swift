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
            popover.delegate = coordinator
            // Not public API, so only used where it exists; without it the arrow simply stays.
            if popover.responds(to: Selector(("setShouldHideAnchor:"))) {
                popover.setValue(true, forKey: "shouldHideAnchor")
            }
            coordinator.popover = popover
            // NSPopover centres itself on the rect it is shown from. Show it, measure how far its
            // content starts from the view's left edge, and move it by that much so the two line up.
            DispatchQueue.main.async {
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                guard let viewWindow = view.window, let content = popover.contentViewController?.view,
                      let contentWindow = content.window else { return }
                let viewLeft = viewWindow.convertToScreen(view.convert(view.bounds, to: nil)).minX
                let contentLeft = contentWindow.convertToScreen(content.convert(content.bounds, to: nil)).minX
                popover.positioningRect = view.bounds.offsetBy(dx: viewLeft - contentLeft, dy: 0)
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
