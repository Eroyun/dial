import AppKit
import SwiftUI

/// A small glass capsule shown at the bottom of a display when a key changes it.
enum HUD {
    @Observable final class Model {
        var symbol = "sun.max.fill"
        var value = 0.0
    }

    private static let model = Model()
    private static var hide: DispatchWorkItem?
    private static let panel: NSPanel = {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 240, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }()

    static func show(symbol: String, value: Double, on display: CGDirectDisplayID) {
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.18)) {
                model.symbol = symbol
                model.value = value
            }
            if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display }) {
                let frame = screen.frame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 96))
            }
            if !panel.isVisible || panel.alphaValue < 1 {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
            }
            hide?.cancel()
            let work = DispatchWorkItem {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 }) {
                    if panel.alphaValue == 0 { panel.orderOut(nil) }
                }
            }
            hide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
        }
    }
}

private struct HUDView: View {
    let model: HUD.Model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.symbol)
                .font(.system(size: 14, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15))
                    Capsule().fill(.primary).frame(width: max(6, geo.size.width * model.value))
                }
            }
            .frame(height: 6)
            Text("\(Int((model.value * 100).rounded()))")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(width: 240, height: 48)
        .glass(in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a material everywhere else.
    @ViewBuilder
    func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
