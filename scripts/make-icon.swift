// Renders the app icon. Run: swift scripts/make-icon.swift  (writes Resources/AppIcon.icns + docs/icon.png)
import AppKit
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            // macOS squircle on the 1024 grid (824 content, 100 margin)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            // tick ring
            ForEach(0..<36) { i in
                let angle = -135.0 + Double(i) * (270.0 / 35.0)
                Capsule()
                    .fill(.white.opacity(i <= 24 ? 0.0 : 0.16))
                    .frame(width: 10, height: i % 5 == 0 ? 44 : 28)
                    .offset(y: -318)
                    .rotationEffect(.degrees(angle))
            }

            // level arc
            Circle()
                .trim(from: 0, to: 0.75 * 24 / 35)
                .stroke(AngularGradient(colors: [Color(red: 1.0, green: 0.42, blue: 0.20), Color(red: 1.0, green: 0.78, blue: 0.30)],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(270 * 24 / 35)),
                        style: StrokeStyle(lineWidth: 40, lineCap: .round))
                .frame(width: 612, height: 612)
                .rotationEffect(.degrees(135))
                .shadow(color: Color(red: 1.0, green: 0.55, blue: 0.2).opacity(0.55), radius: 26)

            // knob
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 4))
                .frame(width: 420, height: 420)
                .shadow(color: .black.opacity(0.6), radius: 30, y: 18)
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.30), Color(white: 0.17)], center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: 220))
                .frame(width: 360, height: 360)

            // pointer
            Capsule()
                .fill(.white)
                .frame(width: 26, height: 110)
                .offset(y: -112)
                .rotationEffect(.degrees(-135 + 270 * 24 / 35))
                .shadow(color: .white.opacity(0.5), radius: 10)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    let png = rep.representation(using: .png, properties: [:])!
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    try! png.write(to: root.appendingPathComponent("docs/icon.png"))

    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = size * scale
            let image = NSImage(size: NSSize(width: px, height: px))
            image.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: cg, size: NSSize(width: 1024, height: 1024)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            image.unlockFocus()
            let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try! data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
        }
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
    try! task.run(); task.waitUntilExit()
    print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")
}

MainActor.assumeIsolated { render() }
