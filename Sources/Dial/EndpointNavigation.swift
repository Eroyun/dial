import Foundation

/// Input bounds used only while seeking a page endpoint before capture begins.
/// Ordinary capture and rollback wheels keep their much smaller bounds.
enum EndpointNavigation {
    static let maximumWheelPixels = 1_000_000
    static let maximumOrdinaryWheelPixels = 180

    /// The image compositor matches the central half of the viewport. Limit
    /// ordinary movement to one fifth so that band retains enough overlap.
    static func ordinaryWheelLimit(viewportHeight: CGFloat) -> Int {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return 0 }
        return Int(min(CGFloat(maximumOrdinaryWheelPixels), max(1, viewportHeight / 5)))
    }

    static func seekWheelPixels(towardTop: Bool) -> Int {
        towardTop ? maximumWheelPixels : -maximumWheelPixels
    }

    static func boundedWheelPixels(_ pixels: Int, endpointSeek: Bool) -> Int {
        let limit = endpointSeek ? maximumWheelPixels : maximumOrdinaryWheelPixels
        return max(-limit, min(limit, pixels))
    }
}
