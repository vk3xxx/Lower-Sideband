import Foundation

@_silgen_name("BZ2_bzBuffToBuffDecompress")
private func bz2BufferDecompress(
    _ destination: UnsafeMutablePointer<CChar>?,
    _ destinationLength: UnsafeMutablePointer<UInt32>?,
    _ source: UnsafeMutablePointer<CChar>?,
    _ sourceLength: UInt32,
    _ small: Int32,
    _ verbosity: Int32
) -> Int32

public enum BZip2 {
    private static let success: Int32 = 0

    public static func decompress(_ data: Data, maximumOutputBytes: Int) throws -> Data {
        guard !data.isEmpty,
              maximumOutputBytes > 0,
              maximumOutputBytes <= ReticulumResourceLimits.maximumAttachmentBytes + 65_536,
              data.count <= Int(UInt32.max),
              maximumOutputBytes <= Int(UInt32.max) else {
            throw ResourceError.invalidManifest
        }

        var output = Data(count: maximumOutputBytes)
        var outputLength = UInt32(maximumOutputBytes)
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { sourceBuffer in
                bz2BufferDecompress(
                    outputBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    &outputLength,
                    UnsafeMutablePointer(mutating: sourceBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)),
                    UInt32(data.count),
                    0,
                    0
                )
            }
        }
        guard status == success else { throw ResourceError.invalidManifest }
        output.removeSubrange(Int(outputLength)..<output.count)
        return output
    }
}
