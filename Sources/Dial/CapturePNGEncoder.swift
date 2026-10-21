import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO writes incrementally and can stop at its next output callback when
/// capture is canceled. No second full-sized NSBitmapImageRep is allocated.
enum CapturePNGEncoder {
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var canceled = false
        func cancel() { lock.lock(); canceled = true; lock.unlock() }
        var isCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
    }

    private final class Sink {
        let cancellation: Cancellation
        var data = Data()
        init(_ cancellation: Cancellation) { self.cancellation = cancellation }
    }

    static func encode(_ image: CGImage, cancellation: Cancellation) -> Data? {
        guard !cancellation.isCanceled, !Task.isCancelled else { return nil }
        let sink = Sink(cancellation)
        let retained = Unmanaged.passRetained(sink)
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            guard !sink.cancellation.isCanceled, count >= 0,
                  count <= 2_049_048_576 - sink.data.count else { return 0 }
            sink.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }, releaseConsumer: { info in
            if let info { Unmanaged<Sink>.fromOpaque(info).release() }
        })
        guard let consumer = CGDataConsumer(info: retained.toOpaque(), cbks: &callbacks) else {
            retained.release(); return nil
        }
        guard let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), !cancellation.isCanceled else { return nil }
        return sink.data
    }
}
