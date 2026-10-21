import CoreGraphics
import Darwin
import Foundation

/// Disk-backed, top-to-bottom premultiplied RGBA rows for whole-page capture.
/// The caller owns seam validation and passes only accepted source row ranges.
final class CaptureRowStore {
    private static let maximumFramePixels = 8_000_000
    private static let maximumAllowedPixels = 512_000_000
    private static let copyChunkBytes = 1_048_576

    let width: Int
    let maximumPixels: Int
    private(set) var height = 0
    private let rowBytes: Int
    private let backing: PrivateFile
    private let writeOperation: (Int32, UnsafeRawPointer, Int, off_t) -> Int
    private var tainted = false

    /// `writeOperation` exists for deterministic disk-failure tests. Production
    /// callers use POSIX pwrite; no file contents leave the private temp store.
    init(width: Int, maximumPixels: Int,
         writeOperation: ((Int32, UnsafeRawPointer, Int, off_t) -> Int)? = nil) throws {
        guard width > 0, maximumPixels > 0,
              maximumPixels <= Self.maximumAllowedPixels,
              width <= maximumPixels,
              width <= Int.max / 4 else { throw StoreError.invalidDimensions }
        let rowBytes = width * 4
        guard maximumPixels <= Int.max / 4,
              maximumPixels * 4 >= rowBytes else { throw StoreError.invalidDimensions }
        let backing: PrivateFile
        do { backing = try PrivateFile() }
        catch { throw StoreError.storageUnavailable }
        self.width = width
        self.maximumPixels = maximumPixels
        self.rowBytes = rowBytes
        self.backing = backing
        self.writeOperation = writeOperation ?? { fd, bytes, count, offset in
            Darwin.pwrite(fd, bytes, count, offset)
        }
    }

    enum StoreError: Error {
        case invalidDimensions
        case storageUnavailable
    }

    /// Exposed internally so tests can verify cleanup without retaining files.
    var storageDirectoryForTesting: URL { backing.directoryURL }
    var storageFileForTesting: URL { backing.fileURL }
    var storageFileModeForTesting: Int? { backing.fileMode }

    /// Seed an empty store with the initial viewport.
    @discardableResult
    func seed(frame: ScrollCaptureFrame) -> Bool {
        guard height == 0, frame.width == width,
              frame.height > 0,
              frame.width <= Self.maximumFramePixels / frame.height,
              frame.height <= maximumPixels / width,
              frame.pixels.count == frame.height * rowBytes else { return false }
        return append(frame: frame, rows: 0..<frame.height, trimming: 0)
    }

    /// Replace `trimming` rows at the current tail, then append the accepted
    /// source row range. The changed span is journaled in memory (at most one
    /// incoming frame); failed writes restore the old bytes and logical height.
    @discardableResult
    func append(frame: ScrollCaptureFrame, rows: Range<Int>, trimming: Int) -> Bool {
        guard !tainted, (height == 0 ? trimming == 0 : trimming < height),
              frame.width == width, frame.height > 0,
              frame.width <= Self.maximumFramePixels / frame.height,
              frame.pixels.count == frame.height * rowBytes,
              rows.lowerBound >= 0, rows.upperBound <= frame.height,
              !rows.isEmpty,
              trimming >= 0 else { return false }

        let retainedRows = height - trimming
        guard rows.count <= maximumPixels / width,
              retainedRows <= maximumPixels / width - rows.count else { return false }
        let nextHeight = retainedRows + rows.count
        let (nextLength, overflow) = nextHeight.multipliedReportingOverflow(by: rowBytes)
        guard !overflow, nextLength <= maximumPixels * 4 else { return false }

        let oldHeight = height
        let oldLength = oldHeight * rowBytes
        let writeOffset = retainedRows * rowBytes
        let appendBytes = rows.count * rowBytes
        let overwrittenBytes = min(trimming, rows.count) * rowBytes
        let backup = readExactly(overwrittenBytes, offset: writeOffset)
        guard overwrittenBytes == 0 || backup != nil else { return false }

        let wrote = frame.pixels.withUnsafeBytes { source -> Bool in
            guard let base = source.baseAddress else { return false }
            let sourceOffset = rows.lowerBound * rowBytes
            return writeExactly(base.advanced(by: sourceOffset), count: appendBytes,
                                offset: writeOffset)
        }
        guard wrote, backing.sync(), backing.resize(nextLength) else {
            let restored = rollback(backup ?? Data(), overwrittenBytes: overwrittenBytes,
                                    offset: writeOffset, oldLength: oldLength)
            if !restored { tainted = true }
            return false
        }
        height = nextHeight
        return true
    }

    /// Clone accepted rows and an optional fixed footer into a separate private
    /// mapped file. Export is read-only with respect to this store.
    func image(footer: ScrollCaptureFrame? = nil, footerRows: Int = 0,
               verticallyFlipped: Bool = false) -> CGImage? {
        guard !Task.isCancelled, !tainted, height > 0,
              footerRows >= 0,
              footerRows == 0 || footer != nil else { return nil }
        if let footer {
            guard footer.width == width, footer.height > 0,
                  footer.width <= Self.maximumFramePixels / footer.height,
                  footer.pixels.count == footer.height * rowBytes,
                  footerRows <= footer.height else { return nil }
        }
        let (totalRows, rowOverflow) = height.addingReportingOverflow(footerRows)
        guard !rowOverflow, totalRows > 0,
              totalRows <= maximumPixels / width else { return nil }
        let (byteCount, byteOverflow) = totalRows.multipliedReportingOverflow(by: rowBytes)
        guard !byteOverflow, byteCount > 0 else { return nil }

        guard let output = try? PrivateFile() else { return nil }
        guard copyRows(to: output, footer: footer, footerRows: footerRows,
                       verticallyFlipped: verticallyFlipped),
              output.resize(byteCount),
              output.sync(),
              let mapped = output.mapReadOnly(byteCount),
              let provider = makeProvider(for: output, mapped: mapped, size: byteCount) else {
            return nil
        }
        return CGImage(width: width, height: totalRows,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                           .union(.byteOrder32Big),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private func copyRows(to output: PrivateFile, footer: ScrollCaptureFrame?, footerRows: Int,
                          verticallyFlipped: Bool) -> Bool {
        let chunkRows = max(1, Self.copyChunkBytes / rowBytes)
        var destinationRow = 0

        func writeFooterRows(reversed: Bool) -> Bool {
            guard footerRows > 0, let footer else { return footerRows == 0 }
            return footer.pixels.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return false }
                let chunks = (footerRows + chunkRows - 1) / chunkRows
                for chunk in 0..<chunks {
                    guard !Task.isCancelled else { return false }
                    let count = min(chunkRows, footerRows - chunk * chunkRows)
                    var buffer = Data(count: count * rowBytes)
                    let copied = buffer.withUnsafeMutableBytes { destination -> Bool in
                        guard let dst = destination.baseAddress else { return false }
                        for row in 0..<count {
                            let selected = reversed
                                ? footer.height - 1 - (chunk * chunkRows + row)
                                : footer.height - footerRows + chunk * chunkRows + row
                            let destinationIndex = row
                            dst.advanced(by: destinationIndex * rowBytes).copyMemory(
                                from: base.advanced(by: selected * rowBytes), byteCount: rowBytes)
                        }
                        return true
                    }
                    guard copied,
                          output.writeExactly(buffer, offset: destinationRow * rowBytes) else { return false }
                    destinationRow += count
                }
                return true
            }
        }

        if verticallyFlipped, !writeFooterRows(reversed: true) { return false }

        if !verticallyFlipped {
            var sourceRow = 0
            while sourceRow < height {
                guard !Task.isCancelled else { return false }
                let count = min(chunkRows, height - sourceRow)
                let bytes = count * rowBytes
                guard let chunk = backing.readExactly(bytes, offset: sourceRow * rowBytes),
                      output.writeExactly(chunk, offset: destinationRow * rowBytes) else { return false }
                sourceRow += count
                destinationRow += count
            }
        } else {
            var sourceEnd = height
            while sourceEnd > 0 {
                guard !Task.isCancelled else { return false }
                let count = min(chunkRows, sourceEnd)
                let sourceStart = sourceEnd - count
                guard var chunk = backing.readExactly(count * rowBytes, offset: sourceStart * rowBytes) else {
                    return false
                }
                let reversed = chunk.withUnsafeMutableBytes { bytes -> Bool in
                    guard let base = bytes.baseAddress else { return false }
                    let row = UnsafeMutableRawPointer.allocate(byteCount: rowBytes, alignment: 16)
                    defer { row.deallocate() }
                    for index in 0..<(count / 2) {
                        let opposite = count - 1 - index
                        row.copyMemory(from: base.advanced(by: index * rowBytes), byteCount: rowBytes)
                        base.advanced(by: index * rowBytes).copyMemory(
                            from: base.advanced(by: opposite * rowBytes), byteCount: rowBytes)
                        base.advanced(by: opposite * rowBytes).copyMemory(from: row, byteCount: rowBytes)
                    }
                    return true
                }
                guard reversed, output.writeExactly(chunk, offset: destinationRow * rowBytes) else { return false }
                sourceEnd = sourceStart
                destinationRow += count
            }
        }

        if !verticallyFlipped, !writeFooterRows(reversed: false) { return false }
        return destinationRow == height + footerRows
    }

    private func writeExactly(_ source: UnsafeRawPointer, count: Int, offset: Int) -> Bool {
        var written = 0
        while written < count {
            let result = writeOperation(backing.fd, source.advanced(by: written), count - written,
                                        off_t(offset + written))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return false }
            written += result
        }
        return true
    }

    private func writeExactly(_ data: Data, offset: Int) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            return writeExactly(base, count: bytes.count, offset: offset)
        }
    }

    private func readExactly(_ count: Int, offset: Int) -> Data? {
        backing.readExactly(count, offset: offset)
    }

    private func rollback(_ backup: Data, overwrittenBytes: Int,
                          offset: Int, oldLength: Int) -> Bool {
        if overwrittenBytes > 0,
           (!writeExactly(backup, offset: offset) || !backing.sync()) { return false }
        return backing.resize(oldLength)
    }

    private func makeProvider(for file: PrivateFile, mapped: UnsafeRawPointer,
                              size: Int) -> CGDataProvider? {
        let retained = Unmanaged.passRetained(file)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: mapped,
                                            size: size, releaseData: Self.releaseProviderData) else {
            retained.release()
            return nil
        }
        return provider
    }

    private static let releaseProviderData: CGDataProviderReleaseDataCallback = { info, _, _ in
        guard let info else { return }
        Unmanaged<PrivateFile>.fromOpaque(info).release()
    }
}

/// One randomly named, owner-only temp directory and file. Output mappings are
/// retained by their CGDataProvider and removed when that image releases them.
private final class PrivateFile {
    let directoryURL: URL
    let fileURL: URL
    let fd: Int32
    private var mappedAddress: UnsafeMutableRawPointer?
    private var mappedSize = 0

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DialCaptureRows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EACCES)
        }
        let file = directory.appendingPathComponent("rows.rgba", isDirectory: false)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.EACCES)
        }
        guard unlink(file.path) == 0 else {
            close(descriptor)
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.directoryURL = directory
        self.fileURL = file
        self.fd = descriptor
    }

    func resize(_ size: Int) -> Bool {
        size >= 0 && ftruncate(fd, off_t(size)) == 0
    }

    func sync() -> Bool { fsync(fd) == 0 }

    var fileMode: Int? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return Int(info.st_mode & mode_t(0o777))
    }

    func readExactly(_ count: Int, offset: Int) -> Data? {
        guard count >= 0, offset >= 0 else { return nil }
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { destination -> Bool in
            guard let base = destination.baseAddress else { return count == 0 }
            var readCount = 0
            while readCount < count {
                let result = pread(fd, base.advanced(by: readCount), count - readCount,
                                   off_t(offset + readCount))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                readCount += result
            }
            return true
        }
        return success ? data : nil
    }

    func writeExactly(_ data: Data, offset: Int) -> Bool {
        data.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return data.isEmpty }
            var written = 0
            while written < source.count {
                let result = Darwin.pwrite(fd, base.advanced(by: written), source.count - written,
                                           off_t(offset + written))
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return false }
                written += result
            }
            return true
        }
    }

    func mapReadOnly(_ size: Int) -> UnsafeRawPointer? {
        guard size > 0, mappedAddress == nil else { return nil }
        let address = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)
        guard address != MAP_FAILED, let address else { return nil }
        mappedAddress = address
        mappedSize = size
        return UnsafeRawPointer(address)
    }

    deinit {
        if let mappedAddress { _ = munmap(mappedAddress, mappedSize) }
        close(fd)
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
