import Foundation
import CoreGraphics
import ImageIO

@main enum CaptureFrameProofTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dial-proof-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        precondition(CaptureFrameProof(directoryPath: directory.path, publicFixture: false) == nil)
        precondition(CaptureFrameProof(directoryPath: nil, publicFixture: true) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        precondition(CaptureFrameProof(directoryPath: directory.path, publicFixture: true) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let frame = try ScrollCaptureFrame(width: 3, height: 2,
            pixels: [10,20,30,255, 40,50,60,255, 70,80,90,255,
                     100,110,120,255, 130,140,150,255, 160,170,180,255])
        let proof = CaptureFrameProof(directoryPath: directory.path, publicFixture: true)!
        proof.record(frame, label: "observation", metadata: [:])
        precondition(proof.frameCount == 0)
        proof.record(frame, label: "reference", metadata: ["showsCursor": "false"])
        proof.record(frame, label: "observation", metadata: ["showsCursor": "false"])
        precondition(proof.frameCount == 2 && proof.issue.isEmpty)
        let before = try Data(contentsOf: directory.appendingPathComponent("reference.png"))
        proof.record(frame, label: "reference", metadata: [:])
        let after = try Data(contentsOf: directory.appendingPathComponent("reference.png"))
        precondition(before == after && proof.frameCount == 2)
        let source = CGImageSourceCreateWithData(before as CFData, nil)!
        precondition(CGImageSourceGetType(source) as String? == "public.png")
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var pixels = [UInt8](repeating: 0, count: frame.pixels.count)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: frame.width, height: frame.height,
                bitsPerComponent: 8, bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        }
        precondition(pixels == frame.pixels, "Proof must preserve every assembler input pixel losslessly")
        precondition(CaptureFrameProof(directoryPath: directory.path, publicFixture: true) == nil,
                     "Existing evidence is never overwritten by another session")
        print("Frame proof: public-only opt-in, private empty directory, two-frame cap, no overwrite and lossless pixels passed")
    }
}
