import Foundation
import CryptoKit

/// The framebuffer format exposed by current RNode firmware: 64 scan lines,
/// eight bytes per line and one bit per pixel.
public struct RNodeFramebuffer: Equatable, Sendable {
    public static let width = 64
    public static let height = 64
    public static let byteCount = 512
    public private(set) var bytes: Data

    public init(bytes: Data = Data(repeating: 0, count: byteCount)) throws {
        guard bytes.count == Self.byteCount else { throw RNodeError.invalidFramebuffer }
        self.bytes = bytes
    }

    public subscript(x: Int, y: Int) -> Bool {
        get {
            guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return false }
            return bytes[y * 8 + x / 8] & (0x80 >> UInt8(x % 8)) != 0
        }
        set {
            guard (0..<Self.width).contains(x), (0..<Self.height).contains(y) else { return }
            let index = y * 8 + x / 8
            let mask: UInt8 = 0x80 >> UInt8(x % 8)
            bytes[index] = newValue ? bytes[index] | mask : bytes[index] & ~mask
        }
    }

    public static func testPattern() -> Self {
        var result = try! Self()
        for coordinate in 0..<64 {
            result[coordinate, coordinate] = true
            result[63 - coordinate, coordinate] = true
            result[coordinate, 0] = true
            result[coordinate, 63] = true
            result[0, coordinate] = true
            result[63, coordinate] = true
        }
        return result
    }
}

public enum RNodeFirmwareValidationError: LocalizedError, Equatable, Sendable {
    case emptyImage, imageTooLarge, digestMismatch, platformMismatch, boardMismatch

    public var errorDescription: String? {
        switch self {
        case .emptyImage: "The RNode firmware image is empty."
        case .imageTooLarge: "The RNode firmware image exceeds the 16 MiB safety limit."
        case .digestMismatch: "The firmware SHA-256 digest does not match its manifest."
        case .platformMismatch: "This firmware package targets a different RNode platform."
        case .boardMismatch: "This firmware package targets a different RNode board."
        }
    }
}

/// A verified firmware payload. Lower Sideband prepares and hands the RNode to
/// its native bootloader; flashing remains a platform bootloader operation.
public struct RNodeFirmwarePackage: Equatable, Sendable {
    public let version: String
    public let platform: UInt8
    public let board: UInt8?
    public let image: Data
    public let sha256: Data

    public init(version: String, platform: UInt8, board: UInt8? = nil, image: Data, sha256: Data) {
        self.version = version
        self.platform = platform
        self.board = board
        self.image = image
        self.sha256 = sha256
    }

    public init(version: String, platform: UInt8, board: UInt8? = nil, trustedImage: Data) {
        self.init(version: version, platform: platform, board: board, image: trustedImage,
                  sha256: Data(SHA256.hash(data: trustedImage)))
    }

    public func validate(against metrics: RNodeMetrics) throws {
        guard !image.isEmpty else { throw RNodeFirmwareValidationError.emptyImage }
        guard image.count <= 16 * 1_024 * 1_024 else { throw RNodeFirmwareValidationError.imageTooLarge }
        guard Data(SHA256.hash(data: image)) == sha256 else { throw RNodeFirmwareValidationError.digestMismatch }
        if let detected = metrics.platform, detected != platform { throw RNodeFirmwareValidationError.platformMismatch }
        if let board, let detected = metrics.board, board != detected { throw RNodeFirmwareValidationError.boardMismatch }
    }
}

public struct RNodeFirmwareUpdatePlan: Equatable, Sendable {
    public let packageVersion: String
    public let currentVersion: String
    public let platform: UInt8
    public let board: UInt8?
    public let imageBytes: Int
    public let digestHex: String
    public let requiresExternalBootloader: Bool

    public init(package: RNodeFirmwarePackage, metrics: RNodeMetrics) throws {
        try package.validate(against: metrics)
        packageVersion = package.version
        currentVersion = if let major = metrics.firmwareMajor, let minor = metrics.firmwareMinor { "\(major).\(minor)" } else { "Unknown" }
        platform = package.platform
        board = package.board
        imageBytes = package.image.count
        digestHex = package.sha256.map { String(format: "%02x", $0) }.joined()
        requiresExternalBootloader = true
    }
}
