import Foundation

public enum ReticulumResourceLimits {
    public static let maximumAttachmentBytes = 64 * 1024 * 1024
    public static let maximumTransferBytes = maximumAttachmentBytes + 1_048_576
    public static let maximumSegments = 65
    public static let maximumConcurrentIncoming = 8
    public static let maximumPartCount = (maximumTransferBytes + ReticulumResourceManifest.defaultSDU - 1) / ReticulumResourceManifest.defaultSDU

    public static func accepts(
        dataSize: Int,
        transferSize: Int,
        partCount: Int,
        segments: Int,
        segmentIndex: Int,
        advertisedPartHashCount: Int,
        sdu: Int = ReticulumResourceManifest.defaultSDU
    ) -> Bool {
        guard (ReticulumResourceManifest.defaultSDU...(0x1f_ffff - 36)).contains(sdu),
              dataSize >= 0, dataSize <= maximumAttachmentBytes + 65_536,
              transferSize >= 0, transferSize <= maximumTransferBytes,
              (0...maximumPartCount).contains(partCount),
              (1...maximumSegments).contains(segments),
              (1...segments).contains(segmentIndex),
              advertisedPartHashCount >= 0 else { return false }
        // Validate untrusted ranges before adding the SDU rounding value so a
        // hostile Int.max transfer claim cannot trap the receiver process.
        let expectedParts = transferSize == 0 ? 0 : (transferSize + sdu - 1) / sdu
        return partCount == expectedParts &&
            advertisedPartHashCount == min(partCount, ReticulumResourceAdvertisement.hashMapMaximumEntries)
    }
}
