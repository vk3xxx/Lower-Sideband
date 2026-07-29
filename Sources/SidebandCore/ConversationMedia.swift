import Foundation

public struct ConversationMediaItem: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case image, file, voice, telemetry, link
    }

    public let id: String
    public let messageID: UUID
    public let date: Date
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let attachment: Attachment?
    public let url: URL?

    public init(id: String, messageID: UUID, date: Date, kind: Kind, title: String, subtitle: String, attachment: Attachment? = nil, url: URL? = nil) {
        self.id = id
        self.messageID = messageID
        self.date = date
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.attachment = attachment
        self.url = url
    }
}

public enum ConversationMediaIndexer {
    public static func index(messages: [Message], conversationID: UUID) -> [ConversationMediaItem] {
        var items: [ConversationMediaItem] = []
        for message in messages where message.conversationID == conversationID {
            for attachment in message.attachments {
                let isImage = attachment.mimeType?.lowercased().hasPrefix("image/") == true
                items.append(ConversationMediaItem(
                    id: "attachment-\(attachment.id.uuidString)",
                    messageID: message.id,
                    date: message.timestamp,
                    kind: isImage ? .image : .file,
                    title: attachment.filename,
                    subtitle: ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file),
                    attachment: attachment
                ))
            }
            if let voice = message.voiceAudio {
                items.append(ConversationMediaItem(
                    id: "voice-\(message.id.uuidString)",
                    messageID: message.id,
                    date: message.timestamp,
                    kind: .voice,
                    title: "Voice message",
                    subtitle: "\(voice.mode) · \(ByteCountFormatter.string(fromByteCount: Int64(voice.encodedAudio.count), countStyle: .file))"
                ))
            }
            if let telemetry = message.telemetry {
                let coordinates = [telemetry.location?.latitude, telemetry.location?.longitude]
                    .compactMap { $0?.formatted(.number.precision(.fractionLength(5))) }
                    .joined(separator: ", ")
                items.append(ConversationMediaItem(
                    id: "telemetry-\(message.id.uuidString)",
                    messageID: message.id,
                    date: message.timestamp,
                    kind: .telemetry,
                    title: "Shared telemetry",
                    subtitle: coordinates.isEmpty ? "Sensor information" : coordinates
                ))
            }
            for (index, token) in message.body.split(whereSeparator: \.isWhitespace).enumerated() {
                let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}<>\"'"))
                guard (trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://")),
                      let url = URL(string: trimmed) else { continue }
                items.append(ConversationMediaItem(
                    id: "link-\(message.id.uuidString)-\(index)",
                    messageID: message.id,
                    date: message.timestamp,
                    kind: .link,
                    title: url.host ?? url.absoluteString,
                    subtitle: url.absoluteString,
                    url: url
                ))
            }
        }
        return items.sorted { $0.date > $1.date }
    }
}
