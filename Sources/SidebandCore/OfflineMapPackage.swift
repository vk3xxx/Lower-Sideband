import ReticulumKit
import Foundation

public struct SidebandOfflineMapManifest: Codable, Hashable, Sendable {
    public var name: String
    public var format: String
    public var minimumZoom: Int
    public var maximumZoom: Int
    public var bounds: [Double]
    public var attribution: String?

    public init(name: String, format: String, minimumZoom: Int, maximumZoom: Int, bounds: [Double], attribution: String? = nil) {
        self.name = String(name.prefix(100)); self.format = format.lowercased()
        self.minimumZoom = minimumZoom; self.maximumZoom = maximumZoom
        self.bounds = bounds; self.attribution = attribution.map { String($0.prefix(500)) }
    }

    public var isValid: Bool {
        !name.isEmpty && ["png", "jpg", "jpeg", "webp", "pbf"].contains(format) &&
        (0...22).contains(minimumZoom) && (minimumZoom...22).contains(maximumZoom) && bounds.count == 4 &&
        bounds.allSatisfy(\.isFinite) && (-180...180).contains(bounds[0]) && (-90...90).contains(bounds[1]) &&
        (-180...180).contains(bounds[2]) && (-90...90).contains(bounds[3]) && bounds[0] <= bounds[2] && bounds[1] <= bounds[3]
    }
}

public enum SidebandOfflineMapPackage {
    public static func tilePath(z: Int, x: Int, y: Int, format: String) -> String? {
        guard (0...22).contains(z), x >= 0, y >= 0, x < (1 << z), y < (1 << z),
              ["png", "jpg", "jpeg", "webp", "pbf"].contains(format.lowercased()) else { return nil }
        return "tiles/\(z)/\(x)/\(y).\(format.lowercased())"
    }

    public static func validate(directory: URL, maximumBytes: Int64 = 2 * 1_024 * 1_024 * 1_024) throws -> SidebandOfflineMapManifest {
        let manifestURL = directory.appending(path: "manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        guard manifestData.count <= 64 * 1_024 else { throw Error.invalidManifest }
        let manifest = try JSONDecoder().decode(SidebandOfflineMapManifest.self, from: manifestData)
        guard manifest.isValid else { throw Error.invalidManifest }
        let root = directory.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw Error.unreadable }
        var total: Int64 = 0, tileCount = 0
        for case let file as URL in enumerator {
            guard file.standardizedFileURL.path.hasPrefix(root) else { throw Error.unsafePath }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
            guard total <= maximumBytes else { throw Error.tooLarge }
            if file.pathExtension.lowercased() == manifest.format { tileCount += 1 }
        }
        guard tileCount > 0 else { throw Error.noTiles }
        return manifest
    }

    public enum Error: Swift.Error { case invalidManifest, unreadable, unsafePath, tooLarge, noTiles }
}

public struct SidebandSituationTrail: Sendable, Equatable {
    public let destinationHash: String
    public let points: [SidebandTelemetry.Location]
    public init(destinationHash: String, samples: [SidebandTelemetry.Location], maximumPoints: Int = 2_000) {
        self.destinationHash = destinationHash
        points = Array(samples.sorted(by: { $0.updatedAt < $1.updatedAt }).suffix(max(1, maximumPoints)))
    }
}
