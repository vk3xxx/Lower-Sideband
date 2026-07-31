import Foundation

public struct SidebandRecoveryDrillReport: Codable, Sendable, Equatable {
    public let runID: UUID
    public let completedAt: Date
    public let snapshotBytes: Int
    public let conversationCount: Int
    public let messageCount: Int
    public let encryptedRoundTripPassed: Bool
    public let tamperDetectionPassed: Bool
    public let atomicWritePassed: Bool

    public var passed: Bool {
        encryptedRoundTripPassed && tamperDetectionPassed && atomicWritePassed
    }
}

public enum SidebandRecoveryError: LocalizedError {
    case checkpointUnavailable
    case drillFailed

    public var errorDescription: String? {
        switch self {
        case .checkpointUnavailable: "No validated restore checkpoint is available."
        case .drillFailed: "The non-destructive recovery drill did not pass every integrity check."
        }
    }
}
