import SwiftUI
import SidebandCore

struct ConversationOrganizerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SidebandStore
    @State private var collection: ConversationSmartCollection = .all
    @State private var tag = ""
    @State private var search = ""
    @State private var selection: Set<UUID> = []

    private var availableTags: [String] {
        Array(Set(store.conversations.flatMap(\.tags))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    private var conversations: [Conversation] {
        store.conversations(in: collection, tag: tag.isEmpty ? nil : tag).filter {
            search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) ||
            $0.destinationHash.localizedCaseInsensitiveContains(search) ||
            $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Picker("Smart collection", selection: $collection) {
                        ForEach(ConversationSmartCollection.allCases) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    Picker("Tag", selection: $tag) {
                        Text("Any tag").tag("")
                        ForEach(availableTags, id: \.self) { Text($0).tag($0) }
                    }
                    Button(selection.count == conversations.count && !conversations.isEmpty ? "Clear Selection" : "Select All") {
                        if selection.count == conversations.count { selection.removeAll() }
                        else { selection = Set(conversations.map(\.id)) }
                    }
                }
                .padding()
                Divider()
                List(conversations) { conversation in
                    Button {
                        if !selection.insert(conversation.id).inserted { selection.remove(conversation.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selection.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(conversation.id) ? .blue : .secondary)
                            VStack(alignment: .leading) {
                                Text(conversation.displayName).font(.headline).foregroundStyle(.primary)
                                Text(conversation.destinationHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if !conversation.tags.isEmpty {
                                    Text(conversation.tags.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if conversation.unreadCount > 0 { Text("\(conversation.unreadCount)").badgeStyle() }
                            if conversation.isPinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                            if conversation.notificationsMuted { Image(systemName: "bell.slash") }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !selection.isEmpty {
                    Divider()
                    ViewThatFits(in: .horizontal) {
                        HStack { actionButtons }
                        ScrollView(.horizontal) { HStack { actionButtons } }
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .searchable(text: $search, prompt: "Search names, IDs or tags")
            .navigationTitle("Organize Conversations")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 680, minHeight: 600)
        .onChange(of: collection) { _, _ in selection.removeAll() }
        .onChange(of: tag) { _, _ in selection.removeAll() }
    }

    @ViewBuilder private var actionButtons: some View {
        Button("Pin", systemImage: "pin") { apply(.pin) }
        Button("Archive", systemImage: "archivebox") { apply(.archive) }
        Button("Mute", systemImage: "bell.slash") { apply(.mute) }
        Button("Mark Read", systemImage: "envelope.open") { apply(.markRead) }
        Menu("More", systemImage: "ellipsis.circle") {
            Button("Unpin") { apply(.unpin) }
            Button("Unarchive") { apply(.unarchive) }
            Button("Unmute") { apply(.unmute) }
            Button("Mark Unread") { apply(.markUnread) }
        }
    }

    private func apply(_ action: ConversationBulkAction) {
        _ = store.applyBulkAction(action, to: selection)
        selection.removeAll()
    }
}

private extension View {
    func badgeStyle() -> some View {
        self.font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(.white).background(.blue, in: Capsule())
    }
}
