import CoreGraphics

enum CaptureSelectionGeometry {
    static let clickJitterThreshold: CGFloat = 4
    static let minimumWidth: CGFloat = 80
    static let minimumHeight: CGFloat = 100

    /// A click captures the display. A drag must meet the normal content-area minimum.
    static func resolve(anchor: CGPoint, end: CGPoint, maximumExcursion: CGFloat, bounds: CGRect) -> CGRect? {
        let display = CGRect(x: 0, y: 0, width: max(0, bounds.standardized.width), height: max(0, bounds.standardized.height))
        guard display.width > 0, display.height > 0 else { return nil }
        guard maximumExcursion <= clickJitterThreshold else {
            let start = clamp(anchor, to: display)
            let finish = clamp(end, to: display)
            let area = CGRect(
                x: min(start.x, finish.x),
                y: min(start.y, finish.y),
                width: abs(start.x - finish.x),
                height: abs(start.y - finish.y)
            )
            guard area.width >= minimumWidth, area.height >= minimumHeight else { return nil }
            return area
        }
        return display
    }

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}
