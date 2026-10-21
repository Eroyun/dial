import CoreGraphics
import Foundation

/// Derives vertical position only when an accessibility full-document frame
/// encloses the stable viewport. Invalid or ambiguous geometry stays unknown.
enum CaptureScrollGeometry {
    private static let tolerance: CGFloat = 3

    static func fraction(documentFrame: CGRect, viewportFrame: CGRect) -> Double? {
        guard finite(documentFrame), finite(viewportFrame) else { return nil }
        let document = documentFrame.standardized
        let viewport = viewportFrame.standardized
        guard document.width > 0, document.height > 0,
              viewport.width > 0, viewport.height > 0,
              document.height > viewport.height,
              document.minX <= viewport.minX + tolerance,
              document.maxX >= viewport.maxX - tolerance,
              document.minY <= viewport.minY + tolerance,
              document.maxY >= viewport.maxY - tolerance else { return nil }

        let travel = viewport.minY - document.minY
        let range = document.height - viewport.height
        guard range > 0 else { return nil }
        let value = Double(travel / range)
        guard value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite
    }
}
