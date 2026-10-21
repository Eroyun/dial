import AppKit
import SwiftUI
import CoreText

/// All edit coordinates are pixels in the original image, with the origin at its top left.
enum CaptureImageTool: String, CaseIterable { case crop, arrow, box, text }

struct CaptureImageAnnotation {
    var tool: CaptureImageTool
    var start: CGPoint
    var end: CGPoint
    var text: String = ""
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
}

enum CaptureImageRenderer {
    enum RenderError: Error { case invalidCrop, imageTooLarge, allocationFailed }
    static let maximumPixels = 40_000_000

    /// Clamp to the source and expand fractional edges to whole pixels. Empty/invalid crops fail.
    static func normalizedCrop(_ crop: CGRect?, width: Int, height: Int) throws -> CGRect {
        guard width > 0, height > 0 else { throw RenderError.invalidCrop }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let crop else { return bounds }
        guard [crop.origin.x, crop.origin.y, crop.size.width, crop.size.height].allSatisfy({ $0.isFinite }) else {
            throw RenderError.invalidCrop
        }
        let clipped = crop.standardized.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { throw RenderError.invalidCrop }
        return clipped.integral.intersection(bounds)
    }

    /// Crop first (CGImage uses top-left pixel coordinates), then rasterize only the selected area.
    /// A crop without annotations retains the source pixels and alpha without a bitmap redraw.
    static func render(source: CGImage, crop: CGRect? = nil,
                       annotations: [CaptureImageAnnotation] = []) throws -> CGImage {
        try Task.checkCancellation()
        let area = try normalizedCrop(crop, width: source.width, height: source.height)
        let width = Int(area.width), height = Int(area.height)
        guard width <= maximumPixels / height else { throw RenderError.imageTooLarge }
        let full = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard let selected = area == full ? source : source.cropping(to: area) else { throw RenderError.invalidCrop }
        let drawable = annotations.filter { $0.tool != .crop && ($0.tool != .text || !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        guard !drawable.isEmpty else { return selected }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.allocationFailed
        }
        context.draw(selected, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -area.minX, y: -area.minY)
        for annotation in drawable {
            try Task.checkCancellation()
            draw(annotation, in: context)
        }
        guard let result = context.makeImage() else { throw RenderError.allocationFailed }
        return result
    }

    static func draw(_ annotation: CaptureImageAnnotation, in context: CGContext) {
        guard [annotation.start.x, annotation.start.y, annotation.end.x, annotation.end.y,
               annotation.lineWidth].allSatisfy({ $0.isFinite }), annotation.lineWidth > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.tool {
        case .crop: break
        case .box:
            context.stroke(CGRect(x: min(annotation.start.x, annotation.end.x),
                                  y: min(annotation.start.y, annotation.end.y),
                                  width: abs(annotation.end.x - annotation.start.x),
                                  height: abs(annotation.end.y - annotation.start.y)))
        case .arrow:
            context.move(to: annotation.start); context.addLine(to: annotation.end); context.strokePath()
            let angle = atan2(annotation.end.y - annotation.start.y, annotation.end.x - annotation.start.x)
            let length = max(12, annotation.lineWidth * 4)
            context.move(to: CGPoint(x: annotation.end.x - length * cos(angle - .pi / 6),
                                    y: annotation.end.y - length * sin(angle - .pi / 6)))
            context.addLine(to: annotation.end)
            context.addLine(to: CGPoint(x: annotation.end.x - length * cos(angle + .pi / 6),
                                       y: annotation.end.y - length * sin(angle + .pi / 6)))
            context.strokePath()
        case .text:
            let fontSize = max(16, annotation.lineWidth * 5)
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let text = String(annotation.text.prefix(500))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.color.cgColor
            ]))
            context.translateBy(x: annotation.start.x, y: annotation.start.y + fontSize)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
        }
    }
}

/// Put this in a ScrollView and size its frame to the desired zoom. No additional editor window.
struct CaptureImageEditor: NSViewRepresentable {
    var image: NSImage
    var pixelSize: CGSize
    var tool: CaptureImageTool
    var crop: CGRect?
    var annotations: [CaptureImageAnnotation]
    var text: String
    var onCrop: (CGRect) -> Void
    var onAnnotation: (CaptureImageAnnotation) -> Void

    func makeNSView(context: Context) -> CaptureImageCanvas { CaptureImageCanvas() }
    func updateNSView(_ view: CaptureImageCanvas, context: Context) {
        view.configuration = self
        view.needsDisplay = true
    }
}

final class CaptureImageCanvas: NSView {
    var configuration: CaptureImageEditor?
    private var anchor: CGPoint?
    private var current: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func pixelPoint(_ event: NSEvent) -> CGPoint? {
        guard let config = configuration, bounds.width > 0, bounds.height > 0,
              config.pixelSize.width > 0, config.pixelSize.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x / bounds.width * config.pixelSize.width, 0), config.pixelSize.width),
                       y: min(max(point.y / bounds.height * config.pixelSize.height, 0), config.pixelSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = pixelPoint(event); current = anchor
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        _ = autoscroll(with: event)
        current = pixelPoint(event)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil; current = nil; needsDisplay = true }
        guard let config = configuration, let start = anchor, let end = pixelPoint(event) else { return }
        if config.tool == .crop {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
            if let normalized = try? CaptureImageRenderer.normalizedCrop(rect, width: Int(config.pixelSize.width), height: Int(config.pixelSize.height)) {
                config.onCrop(normalized)
            }
        } else if config.tool == .text {
            if !config.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                config.onAnnotation(CaptureImageAnnotation(tool: .text, start: start, end: start, text: config.text))
            }
        } else if hypot(end.x - start.x, end.y - start.y) >= 2 {
            config.onAnnotation(CaptureImageAnnotation(tool: config.tool, start: start, end: end))
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let config = configuration, config.pixelSize.width > 0, config.pixelSize.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        config.image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.saveGState()
        context.scaleBy(x: bounds.width / config.pixelSize.width, y: bounds.height / config.pixelSize.height)
        for annotation in config.annotations { CaptureImageRenderer.draw(annotation, in: context) }
        if let start = anchor, let end = current, config.tool != .crop {
            CaptureImageRenderer.draw(CaptureImageAnnotation(tool: config.tool, start: start, end: end, text: config.text), in: context)
        }
        let dragCrop = config.tool == .crop ? anchor.flatMap { start in current.map { end in
            CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        }} : nil
        if let crop = dragCrop ?? config.crop {
            let outside = CGMutablePath()
            outside.addRect(CGRect(origin: .zero, size: config.pixelSize)); outside.addRect(crop)
            context.addPath(outside); context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
            context.drawPath(using: .eoFill)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2 * config.pixelSize.width / max(bounds.width, 1))
            context.stroke(crop)
        }
        context.restoreGState()
    }
}
