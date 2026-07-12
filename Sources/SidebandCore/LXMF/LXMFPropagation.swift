import Foundation

public enum LXMFPropagation {
    public static let messageGetPath = "/get"
    public static let messageGetPathHash = ReticulumIdentity.truncatedHash(Data(messageGetPath.utf8))

    public static func messageListRequest(timestamp: Double = Date().timeIntervalSince1970) -> Data {
        MessagePack.array([
            MessagePack.double(timestamp),
            MessagePack.binary(messageGetPathHash),
            MessagePack.array([MessagePack.null, MessagePack.null])
        ])
    }

    public static func messageDownloadRequest(_ transientIDs: [Data], timestamp: Double = Date().timeIntervalSince1970) -> Data {
        request(timestamp: timestamp, want: transientIDs, have: [])
    }

    public static func acknowledgementRequest(_ transientIDs: [Data], timestamp: Double = Date().timeIntervalSince1970) -> Data {
        request(timestamp: timestamp, want: nil, have: transientIDs)
    }

    private static func request(timestamp: Double, want: [Data]?, have: [Data]) -> Data {
        let wants = want.map { MessagePack.array($0.map(MessagePack.binary)) } ?? MessagePack.null
        let haves = MessagePack.array(have.map(MessagePack.binary))
        return MessagePack.array([MessagePack.double(timestamp), MessagePack.binary(messageGetPathHash), MessagePack.array([wants, haves])])
    }
}
