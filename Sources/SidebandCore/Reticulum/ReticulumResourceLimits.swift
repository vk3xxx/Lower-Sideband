import Foundation

public enum ReticulumResourceLimits {
    public static let maximumAttachmentBytes = 64 * 1024 * 1024
    public static let maximumSegments = 65
    public static let maximumConcurrentIncoming = 8

    public static func accepts(dataSize: Int, transferSize: Int, segments: Int) -> Bool {
        dataSize >= 0 && dataSize <= maximumAttachmentBytes + 65_536 && transferSize >= 0 && transferSize <= maximumAttachmentBytes + 1_048_576 && (1...maximumSegments).contains(segments)
    }
}
