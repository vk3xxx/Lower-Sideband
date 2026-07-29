import Foundation

/// Reticulum's simplified HDLC stream framing, used by TCP and pipe interfaces.
public enum HDLC {
    public static let flag: UInt8 = 0x7e
    public static let escape: UInt8 = 0x7d
    public static let escapeMask: UInt8 = 0x20

    public static func frame(_ payload: Data) -> Data {
        var result = Data([flag])
        for byte in payload {
            if byte == flag || byte == escape {
                result.append(escape)
                result.append(byte ^ escapeMask)
            } else {
                result.append(byte)
            }
        }
        result.append(flag)
        return result
    }
}

/// Incremental decoder supporting arbitrary TCP chunk boundaries and consecutive flags.
public struct HDLCDecoder: Sendable {
    public var maximumFrameSize: Int
    private var buffer = Data()
    private var insideFrame = false
    private var escaped = false

    public init(maximumFrameSize: Int = 262_144) { self.maximumFrameSize = maximumFrameSize }

    public mutating func consume(_ bytes: Data) -> [Data] {
        var frames: [Data] = []
        for byte in bytes {
            if byte == HDLC.flag {
                if insideFrame, !buffer.isEmpty { frames.append(buffer) }
                buffer.removeAll(keepingCapacity: true)
                insideFrame = true
                escaped = false
            } else if insideFrame {
                if escaped {
                    buffer.append(byte ^ HDLC.escapeMask)
                    escaped = false
                } else if byte == HDLC.escape {
                    escaped = true
                } else {
                    buffer.append(byte)
                }
                if buffer.count > maximumFrameSize {
                    buffer.removeAll(keepingCapacity: true)
                    insideFrame = false
                    escaped = false
                }
            }
        }
        return frames
    }
}
