import CoreGraphics
import Darwin
import Foundation

@main enum CaptureRowStoreTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String = "Check failed",
                      file: StaticString = #file, line: UInt = #line) {
        precondition(condition(), message, file: file, line: line)
    }

    static func main() throws {
        let startingDirectories = temporaryDirectories()
        var store: CaptureRowStore? = try CaptureRowStore(width: 2, maximumPixels: 100)
        let storeDirectory = store!.storageDirectoryForTesting
        let storeFile = store!.storageFileForTesting
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: storeDirectory.path)
        check((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              "Store directory must be owner-only")
        check(store!.storageFileModeForTesting == 0o600,
              "Store file must be owner-only")
        check(!FileManager.default.fileExists(atPath: storeFile.path), "Unlinked scratch data must not survive a process exit")
        let initial = try frame([10, 20, 30, 40])
        check(store!.seed(frame: initial), "Initial rows should seed the store")
        check(store!.height == 4)

        let incoming = try frame([100, 101, 102, 103])
        check(store!.append(frame: incoming, rows: 1..<3, trimming: 2),
              "A validated tail replacement should append")
        check(store!.height == 4)
        check(markers(store!.image()) == [10, 20, 101, 102])

        let footer = try frame([200, 201, 202, 203])
        var exported: CGImage? = store!.image(footer: footer, footerRows: 2)
        check(markers(exported) == [10, 20, 101, 102, 202, 203],
              "Footer rows should be copied after the composed page")
        exported = nil
        check(markers(store!.image()) == [10, 20, 101, 102],
              "Footer export must not mutate stored page rows")

        exported = store!.image(footer: footer, footerRows: 2, verticallyFlipped: true)
        check(markers(exported) == [203, 202, 102, 101, 20, 10],
              "Vertical flipping applies to the composed body and footer")
        exported = nil

        let beforeReject = markers(store!.image())
        check(!store!.append(frame: incoming, rows: 2..<5, trimming: 0),
              "Out-of-bounds source ranges must be rejected")
        check(!store!.append(frame: incoming, rows: 0..<1, trimming: store!.height),
              "A tail trim cannot remove the whole store")
        check(store!.height == 4 && markers(store!.image()) == beforeReject,
              "Rejected operations must preserve rows and height")

        var failNextWrite = false
        var transactional: CaptureRowStore? = try CaptureRowStore(width: 2, maximumPixels: 100,
            writeOperation: { fd, bytes, count, offset in
                if failNextWrite {
                    failNextWrite = false
                    errno = EIO
                    return -1
                }
                return Darwin.pwrite(fd, bytes, count, offset)
            })
        let transactionalInitial = try frame([31, 32, 33])
        check(transactional!.seed(frame: transactionalInitial), "Transactional store should seed")
        let preFailure = markers(transactional!.image())
        failNextWrite = true
        let failingFrame = try frame([90, 91, 92])
        check(!transactional!.append(frame: failingFrame, rows: 0..<1, trimming: 1),
              "Injected write failure should reject the append")
        check(transactional!.height == 3 && markers(transactional!.image()) == preFailure,
              "A failed tail write must restore the previous state")

        var failurePhase = -1
        var partial: CaptureRowStore? = try CaptureRowStore(width: 2, maximumPixels: 100,
            writeOperation: { fd, bytes, count, offset in
                if failurePhase == 0 { failurePhase = 1; return Darwin.pwrite(fd, bytes, max(1, count / 2), offset) }
                if failurePhase == 1 { failurePhase = 2; errno = EIO; return -1 }
                return Darwin.pwrite(fd, bytes, count, offset)
            })
        check(partial!.seed(frame: transactionalInitial))
        failurePhase = 0
        check(!partial!.append(frame: failingFrame, rows: 0..<2, trimming: 2))
        check(partial!.height == 3 && markers(partial!.image()) == preFailure,
              "A partially written tail must be restored byte for byte")
        partial = nil

        exported = store!.image(footer: footer, footerRows: 2)

        let storeURL = store!.storageDirectoryForTesting
        store = nil
        check(!FileManager.default.fileExists(atPath: storeURL.path),
              "Store temp directory should be removed at teardown")
        check(markers(exported) == [10, 20, 101, 102, 202, 203],
              "An exported image owns a cloned provider independent of the store")
        exported = nil
        let transactionalURL = transactional!.storageDirectoryForTesting
        transactional = nil
        check(!FileManager.default.fileExists(atPath: transactionalURL.path),
              "Failed-append temp directory should be removed at teardown")
        check(temporaryDirectories() == startingDirectories,
              "Export provider temp files should be removed when their images release")

        print("Capture row store: append, tail trim, footer export, flip, rollback, bounds, and cleanup passed")
    }

    private static func frame(_ markers: [UInt8]) throws -> ScrollCaptureFrame {
        var pixels: [UInt8] = []
        for marker in markers {
            for _ in 0..<2 { pixels += [marker, marker, marker, 255] }
        }
        return try ScrollCaptureFrame(width: 2, height: markers.count, pixels: pixels)
    }

    private static func markers(_ image: CGImage?) -> [UInt8]? {
        guard let image, let provider = image.dataProvider,
              let data = provider.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let rowBytes = image.bytesPerRow
        return (0..<image.height).map { bytes[$0 * rowBytes] }
    }

    private static func temporaryDirectories() -> Set<String> {
        let root = FileManager.default.temporaryDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Set(urls.filter { $0.lastPathComponent.hasPrefix("DialCaptureRows-") }
            .map(\.lastPathComponent))
    }
}
