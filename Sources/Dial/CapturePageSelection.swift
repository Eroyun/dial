import CoreGraphics

/// A dragged crop identifies its content at the middle, independently of drag
/// direction. The anchor can be a toolbar, sidebar, or boundary between panes.
enum CapturePageSelection {
    static func contentPoint(rect: CGRect, windowBounds: CGRect) -> CGPoint? {
        guard finite(rect), finite(windowBounds) else { return nil }
        let area = rect.standardized.intersection(windowBounds.standardized)
        guard !area.isNull, area.width >= 80, area.height >= 100 else { return nil }
        return CGPoint(x: area.midX, y: area.midY)
    }

    private static func finite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite
    }
}
