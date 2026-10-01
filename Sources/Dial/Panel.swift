import ServiceManagement
import SwiftUI

struct Panel: View {
    let displays: DisplayStore
    let touch: TouchController
    let keys: KeyRouter

    var body: some View {
        VStack(spacing: 10) {
            header
            if displays.displays.isEmpty {
                empty
            } else {
                ForEach(displays.displays) { DisplayCard(display: $0, all: displays.displays) }
            }
            if touch.available { TouchCard(touch: touch) }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "dial.medium.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Dial")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Spacer()
            Menu {
                if Access.shared.granted {
                    Toggle("Keyboard brightness & volume", isOn: Binding(get: { keys.wanted }, set: { keys.wanted = $0 }))
                } else {
                    Button("Use keyboard brightness & volume…") { keys.wanted = true; Access.shared.ask() }
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { try? $0 ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                ))
                Divider()
                Button("Quit Dial") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No external displays")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .card()
    }

}

private struct DisplayCard: View {
    let display: ExternalDisplay
    let all: [ExternalDisplay]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "display")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(display.detail)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !display.modes.isEmpty { ModeRow(display: display, all: all) }
            if let brightness = display.brightness {
                DialSlider(value: brightness, symbol: "sun.max.fill") { display.setBrightness($0) }
            }
            if let volume = display.volume {
                DialSlider(value: volume, symbol: volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill", variable: true) { display.setVolume($0) }
            }
            if display.brightness == nil && display.volume == nil {
                Text(display.supportsDDC ? "Reading…" : "This screen doesn't allow brightness control")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .card()
    }
}

private struct TouchCard: View {
    let touch: TouchController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: touch.enabled ? "hand.tap.fill" : "hand.raised.slash.fill")
                .font(.system(size: 14))
                .foregroundStyle(touch.enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text("Touch screen").font(.system(size: 12, weight: .semibold))
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            DialSwitch(isOn: touch.enabled, label: "Touch screen") { touch.setEnabled($0) }
        }
        .padding(12)
        .card()
    }

    private var status: String {
        if touch.waitingForPermission { return "Turn on Dial in Settings to finish" }
        return touch.enabled ? "On" : "Off · touches are ignored"
    }
}

/// "Looks like" size, tap to open a short scrolling list of sizes; refresh rate as a small pill.
private struct ModeRow: View {
    let display: ExternalDisplay
    let all: [ExternalDisplay]
    private var open: Bool { display.showingSizes }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { withAnimation(.snappy(duration: 0.2)) {
                    // One list open at a time keeps the panel shorter than the screen.
                    let open = !display.showingSizes
                    all.forEach { $0.showingSizes = false }
                    display.showingSizes = open
                } } label: {
                    HStack(spacing: 6) {
                        Text(display.current.map { "Looks like \($0.sizeLabel)" } ?? "–")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .fixedSize()
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(.primary.opacity(0.07), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Screen size")
                .accessibilityValue(display.current?.sizeLabel ?? "")
                Menu {
                    ForEach(display.refreshRates) { mode in
                        Button { display.select(refresh: mode) } label: {
                            if mode.hz == display.current?.hz { Label("\(mode.hz) Hz", systemImage: "checkmark") } else { Text("\(mode.hz) Hz") }
                        }
                    }
                } label: {
                    Pill(text: display.current.map { "\($0.hz) Hz" } ?? "–")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize()
                .disabled(display.refreshRates.count < 2)
            }
            if open { SizeList(display: display).transition(.opacity) }
        }
    }
}

/// Every size the screen offers, in a box that scrolls instead of growing.
private struct SizeList: View {
    let display: ExternalDisplay

    /// About eight rows, less on short screens so the panel never runs off the screen.
    static var height: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return min(236, max(120, screen - 560))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(display.resolutions) { mode in
                        let chosen = mode.sizeLabel == display.current?.sizeLabel
                        Button { display.select(size: mode) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .opacity(chosen ? 1 : 0)
                                    .frame(width: 12)
                                Text(mode.sizeLabel)
                                    .font(.system(size: 12.5, weight: chosen ? .semibold : .regular, design: .rounded))
                                    .monospacedDigit()
                                Spacer(minLength: 0)
                                if mode.sizeLabel == display.nativeSize { Tag(text: "Native") }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(chosen ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(mode.sizeLabel)
                    }
                }
                .padding(3)
            }
            .frame(height: Self.height)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .onAppear { proxy.scrollTo(display.current?.sizeLabel, anchor: .center) }
        }
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(.primary.opacity(0.07), in: Capsule())
    }
}

private struct Pill: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.primary.opacity(0.07), in: Capsule())
        .contentShape(Capsule())
    }
}

struct DialSwitch: View {
    let isOn: Bool
    var label = ""
    let onChange: (Bool) -> Void

    var body: some View {
        Button { withAnimation(.snappy(duration: 0.22)) { onChange(!isOn) } } label: { knob }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(isOn ? "On" : "Off")
    }

    private var knob: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(.primary.opacity(0.92)) : AnyShapeStyle(.primary.opacity(0.12)))
            .frame(width: 38, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .padding(3)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
            }
            .contentShape(Capsule())
    }
}

/// Control Center–style capsule slider: the fill is the value, the icon lives inside.
struct DialSlider: View {
    let value: Double
    let symbol: String
    var variable = false
    let onChange: (Double) -> Void

    @GestureState private var dragging = false
    private let height: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let fill = max(height, geo.size.width * value)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.09))
                Capsule()
                    .fill(.primary.opacity(dragging ? 1 : 0.92))
                    .frame(width: fill)
                Image(systemName: symbol, variableValue: variable ? value : nil)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: height, height: height)
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 11)
                    .opacity(fill > geo.size.width - 34 ? 0 : 1)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { drag in onChange((drag.location.x / geo.size.width).clamped) }
            )
        }
        .frame(height: height)
        .scaleEffect(dragging ? 1.015 : 1)
        .animation(.snappy(duration: 0.18), value: dragging)
    }
}

private extension View {
    func card() -> some View {
        background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}
