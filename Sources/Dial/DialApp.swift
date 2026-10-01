import SwiftUI

@main
struct DialApp: App {
    // Plain lets, not @State: the app is created once, and SwiftUI's @State macro
    // is not available when building with the Command Line Tools alone.
    private let displays: DisplayStore
    private let touch = TouchController()
    private let keys: KeyRouter

    init() {
        if CommandLine.arguments.contains("--probe") { Probe.run() }
        if let i = CommandLine.arguments.firstIndex(of: "--set") { Probe.set(Array(CommandLine.arguments.dropFirst(i + 1))) }
        NSApplication.shared.setActivationPolicy(.accessory)
        let displays = DisplayStore()
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Probe.snapshot(Panel(displays: displays, touch: touch, keys: KeyRouter(store: displays)), to: CommandLine.arguments[i + 1])
        }
        self.displays = displays
        self.keys = KeyRouter(store: displays)
    }

    var body: some Scene {
        MenuBarExtra {
            Panel(displays: displays, touch: touch, keys: keys)
        } label: {
            Image(systemName: "dial.medium.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// `Dial --probe` prints what Dial can see, for bug reports.
/// `Dial --set <display> brightness|volume <0-100>` sets a value from scripts.
enum Probe {
    static func run() -> Never {
        let services = AVServiceLocator.externalServices()
        print("I2C services: \(services.map { "\($0.name) [\($0.vendor):\($0.product)]" })")
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) == 0 {
            let match = AVServiceLocator.match(for: id, in: services)
            let brightness = match?.ddc.read(.brightness).map { "\($0.current)/\($0.max)" } ?? "–"
            let volume = match?.ddc.read(.volume).map { "\($0.current)/\($0.max)" } ?? "–"
            print("display \(id) [\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id))] → \(match?.name ?? "no I2C service")  brightness=\(brightness) volume=\(volume)")
        }
        exit(0)
    }

    /// Renders the panel to a PNG (used for the README screenshot).
    @MainActor static func snapshot(_ panel: Panel, to path: String) -> Never {
        RunLoop.main.run(until: Date().addingTimeInterval(1.5)) // let DDC reads land
        for scheme in [ColorScheme.dark, .light] {
            let view = panel
                .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(24)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let file = path.replacingOccurrences(of: ".png", with: "-\(scheme == .dark ? "dark" : "light").png")
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: file))
                print("wrote \(file)")
            }
        }
        exit(0)
    }

    static func set(_ args: [String]) -> Never {
        guard args.count == 3, let percent = Double(args[2]),
              let vcp: DDC.VCP = args[1] == "brightness" ? .brightness : args[1] == "volume" ? .volume : nil else {
            print("usage: Dial --set <display name> brightness|volume <0-100>"); exit(2)
        }
        guard let match = AVServiceLocator.externalServices().first(where: { $0.name.localizedCaseInsensitiveContains(args[0]) }),
              let current = match.ddc.read(vcp) else {
            print("no display matching \(args[0]) with \(args[1]) control"); exit(1)
        }
        let value = UInt16((percent / 100).clamped * Double(current.max))
        let ok = match.ddc.write(vcp, value)
        let after = match.ddc.read(vcp).map { "\($0.current)/\($0.max)" } ?? "?"
        print("\(match.name) \(args[1]): \(current.current) → \(value) (\(ok ? "ok" : "write failed"), reads back \(after))")
        exit(ok ? 0 : 1)
    }
}
