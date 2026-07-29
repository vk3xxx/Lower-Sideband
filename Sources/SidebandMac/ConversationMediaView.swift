import SwiftUI
import SidebandCore
import QuickLook
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ConversationMediaView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    let conversation: Conversation
    @State private var kind: ConversationMediaItem.Kind?
    @State private var search = ""
    @State private var previewURL: URL?
    @State private var previewAttachment: Attachment?

    private var filtered: [ConversationMediaItem] {
        store.mediaItems(for: conversation.id).filter { item in
            (kind == nil || item.kind == kind) &&
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.subtitle.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "No Shared Content",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Images, files, voice messages, telemetry and links in this conversation will appear here.")
                    )
                }
                ForEach(filtered) { item in
                    Button { open(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(item.kind))
                                .font(.title2).foregroundStyle(color(item.kind)).frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline).foregroundStyle(.primary)
                                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(item.attachment == nil && item.url == nil)
                }
            }
            .searchable(text: $search, prompt: "Search shared content")
            .navigationTitle("Media & Files")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("All") { kind = nil }
                        ForEach(ConversationMediaItem.Kind.allCases, id: \.self) { value in
                            Button(value.rawValue.capitalized) { kind = value }
                        }
                    } label: {
                        Label(kind?.rawValue.capitalized ?? "All", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, value in
            if value == nil, let attachment = previewAttachment {
                previewAttachment = nil
                Task { await store.attachmentStore.removeMaterializedFile(for: attachment) }
            }
        }
    }

    private func open(_ item: ConversationMediaItem) {
        if let url = item.url {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        } else if let attachment = item.attachment {
            Task {
                do {
                    previewAttachment = attachment
                    previewURL = try await store.attachmentStore.materializedURL(for: attachment)
                } catch {
                    store.lastError = "Could not open \(attachment.filename): \(error.localizedDescription)"
                }
            }
        }
    }

    private func icon(_ kind: ConversationMediaItem.Kind) -> String {
        switch kind {
        case .image: "photo"
        case .file: "doc"
        case .voice: "waveform"
        case .telemetry: "location"
        case .link: "link"
        }
    }

    private func color(_ kind: ConversationMediaItem.Kind) -> Color {
        switch kind {
        case .image: .purple
        case .file: .blue
        case .voice: .orange
        case .telemetry: .green
        case .link: .cyan
        }
    }
}
