import SidebandCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct NetworkMapView: View {
    @Bindable var store: SidebandStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var snapshot = NetworkMapSnapshot.empty
    @State private var searchQuery = ""
    @State private var maximumHops = 4
    @State private var showAllHops = false
    @State private var showOffline = true
    @AppStorage("networkMap.showDestinations") private var showDestinations = true
    @State private var autoRefresh = true
    @State private var showControls = true
    @State private var selectedNodeID: String?
    @State private var hoveredNodeID: String?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?
    @State private var isRefreshing = false
    #if os(macOS)
    @State private var hostingWindow: NSWindow?
    @State private var isFullScreen = false
    #endif

    private var filteredSnapshot: NetworkMapSnapshot {
        NetworkMapFilter(
            query: searchQuery,
            maximumHops: showAllHops ? nil : UInt8(clamping: maximumHops),
            showOffline: showOffline,
            showDestinations: showDestinations
        ).apply(to: snapshot)
    }

    private var positions: [String: NetworkMapPosition] {
        NetworkMapLayout.positions(for: filteredSnapshot)
    }

    private var selectedNode: NetworkMapNode? {
        guard let selectedNodeID else { return nil }
        return filteredSnapshot.nodes.first { $0.id == selectedNodeID }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack {
                    Color.networkMapBackground.ignoresSafeArea()
                    topologyCanvas(size: proxy.size)
                    controls(availableWidth: proxy.size.width)
                    legend
                    if let selectedNode {
                        nodeInspector(selectedNode, availableWidth: proxy.size.width)
                    }
                    if let hoveredNode = hoveredNodeID.flatMap({ id in filteredSnapshot.nodes.first { $0.id == id } }),
                       selectedNodeID != hoveredNode.id {
                        hoverCard(hoveredNode)
                    }
                }
                .clipped()
            }
            .navigationTitle("Reticulum Network Map")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        animate { showControls.toggle() }
                    } label: {
                        Label(showControls ? "Hide controls" : "Show controls", systemImage: "slider.horizontal.3")
                    }
                    .help(showControls ? "Hide network-map controls" : "Show network-map controls")

                    Button {
                        resetViewport()
                    } label: {
                        Label("Fit network", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Fit the complete filtered Reticulum topology")

                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .help("Refresh paths, interfaces and destinations now")

                    Button {
                        animate {
                            showDestinations.toggle()
                            clearHiddenSelection()
                        }
                    } label: {
                        Label(
                            showDestinations ? "Hide individual destinations" : "Show individual destinations",
                            systemImage: showDestinations ? "person.2.slash" : "person.2"
                        )
                    }
                    .accessibilityIdentifier("network-map-toggle-destinations")
                    .help(
                        showDestinations
                            ? "Hide people and other individual LXMF destinations while keeping the network backbone visible"
                            : "Show people and other individual LXMF destinations on the network map"
                    )

                    #if os(macOS)
                    Button {
                        toggleFullScreen()
                    } label: {
                        Label(
                            isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                            systemImage: isFullScreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right"
                        )
                    }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                    .accessibilityIdentifier("network-map-full-screen")
                    .help(
                        isFullScreen
                            ? "Return the Reticulum network map to its window (Control-Command-F)"
                            : "Show the Reticulum network map full screen (Control-Command-F)"
                    )

                    Button("Close") { dismiss() }
                        .keyboardShortcut("w", modifiers: .command)
                        .help("Close the Reticulum network map window")
                    #else
                    Button("Done") { dismiss() }
                    #endif
                }
            }
        }
        .task(id: autoRefresh) {
            await refresh()
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard autoRefresh, !Task.isCancelled else { break }
                await refresh()
            }
        }
        .onChange(of: searchQuery) {
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if query.isEmpty {
                selectedNodeID = nil
            } else {
                selectedNodeID = filteredSnapshot.nodes.first(where: { node in
                    guard node.kind == .destination || node.kind == .propagationNode else { return false }
                    return [node.label, node.detail, node.destinationHash ?? ""]
                        .joined(separator: " ")
                        .lowercased()
                        .contains(query)
                })?.id
            }
        }
        .onChange(of: showDestinations) {
            clearHiddenSelection()
            resetViewport()
        }
        #if os(macOS)
        .background {
            NetworkMapWindowReader { window in
                hostingWindow = window
                isFullScreen = window.styleMask.contains(.fullScreen)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            guard notification.object as? NSWindow === hostingWindow else { return }
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            guard notification.object as? NSWindow === hostingWindow else { return }
            isFullScreen = false
        }
        #endif
        .platformNetworkMapSize()
    }

    private func topologyCanvas(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let filtered = filteredSnapshot
            let screenPositions = screenPositions(in: canvasSize)

            for edge in filtered.edges {
                guard let start = screenPositions[edge.sourceID], let end = screenPositions[edge.targetID] else { continue }
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                let selected = selectedNodeID == edge.sourceID || selectedNodeID == edge.targetID
                let color: Color = edge.kind == .direct ? .green : (edge.kind == .interface ? .teal : .blue)
                context.stroke(
                    path,
                    with: .color(color.opacity(selected ? 0.95 : 0.48)),
                    style: StrokeStyle(
                        lineWidth: selected ? 2.6 : 1.25,
                        lineCap: .round,
                        dash: {
                            if edge.kind == .multiHop { return differentiateWithoutColor ? [7, 4] : [4, 4] }
                            if differentiateWithoutColor, edge.kind == .interface { return [1, 3] }
                            return []
                        }()
                    )
                )
            }

            for node in filtered.nodes {
                guard let point = screenPositions[node.id] else { continue }
                draw(node: node, at: point, context: &context)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = pan }
                    let origin = dragOrigin ?? pan
                    pan = CGSize(width: origin.width + value.translation.width, height: origin.height + value.translation.height)
                }
                .onEnded { _ in dragOrigin = nil }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if zoomOrigin == nil { zoomOrigin = zoom }
                    zoom = min(4.5, max(0.45, (zoomOrigin ?? zoom) * value.magnification))
                }
                .onEnded { _ in zoomOrigin = nil }
        )
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in selectNode(at: value.location, size: size) }
        )
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoveredNodeID = hitNode(at: location, size: size)?.id
            case .ended: hoveredNodeID = nil
            }
        }
        #endif
        .accessibilityLabel("Interactive Reticulum topology")
        .accessibilityValue(
            "\(filteredSnapshot.nodes.count) nodes and \(filteredSnapshot.edges.count) links"
                + (selectedNode.map { ", selected \($0.label), \($0.status.displayName)" } ?? "")
        )
        .accessibilityHint("Drag to pan, pinch or scroll to zoom, and select a node for route details")
    }

    private func draw(node: NetworkMapNode, at point: CGPoint, context: inout GraphicsContext) {
        let selected = selectedNodeID == node.id
        let hovered = hoveredNodeID == node.id
        let radius = node.kind == .local ? 22.0 : (node.kind == .interface || node.kind == .transport ? 18.0 : 15.0)
        let scale = selected || hovered ? 1.17 : 1
        let rect = CGRect(
            x: point.x - radius * scale, y: point.y - radius * scale,
            width: radius * 2 * scale, height: radius * 2 * scale
        )
        if selected || hovered {
            context.fill(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(node.color.opacity(0.22)))
        }
        context.fill(Path(ellipseIn: rect), with: .color(node.color))
        context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.75)), lineWidth: selected ? 2.5 : 1)

        let icon = context.resolve(
            Text(Image(systemName: node.symbolName))
                .font(.system(size: radius * 0.82, weight: .semibold))
                .foregroundStyle(.white)
        )
        context.draw(icon, at: point)

        let shouldLabel = zoom >= 0.78 || selected || hovered || !searchQuery.isEmpty || node.kind == .local
        if shouldLabel {
            let label = context.resolve(
                Text(node.label)
                    .font(.caption2.weight(selected ? .bold : .semibold))
                    .foregroundStyle(.primary)
            )
            context.draw(label, at: CGPoint(x: point.x, y: point.y + radius * scale + 7), anchor: .top)
        }
    }

    private func controls(availableWidth: CGFloat) -> some View {
        VStack {
            HStack {
                if showControls {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reticulum Mesh").font(.headline)
                                Text(snapshot.generatedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isRefreshing { ProgressView().controlSize(.small) }
                        }

                        TextField("Search nodes or destination IDs", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)

                        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Label {
                                Text("Reticulum reveals the next hop and total distance. Question-mark nodes are relay positions whose identities are not exposed.")
                            } icon: {
                                Image(systemName: "info.circle.fill")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(9)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        }

                        HStack(spacing: 8) {
                            metric(title: "Nodes", value: filteredSnapshot.nodes.count, color: .blue)
                            metric(title: "Links", value: filteredSnapshot.edges.count, color: .green)
                        }

                        HStack(spacing: 7) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("\(snapshot.onlineInterfaceCount) online")
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text("\(snapshot.offlineInterfaceCount) offline")
                        }
                        .font(.caption)

                        Toggle("Auto update", isOn: $autoRefresh)
                        Toggle("Show individual destinations", isOn: $showDestinations)
                            .help("Show or hide people, bots and other individual LXMF destinations")
                        Toggle("Show unavailable nodes", isOn: $showOffline)
                        Toggle("Show all hop counts", isOn: $showAllHops)
                        if !showAllHops {
                            HStack {
                                Text("Maximum hops")
                                Spacer()
                                Text("\(maximumHops)").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: Binding(
                                get: { Double(maximumHops) },
                                set: { maximumHops = Int($0.rounded()) }
                            ), in: 1...16, step: 1)
                        }

                        HStack {
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                            Button("Fit", systemImage: "viewfinder") { resetViewport() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(14)
                    .frame(width: min(286, max(200, availableWidth - 32)))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer()
            }
            Spacer()
        }
        .padding()
        .animation(reduceMotion ? nil : .snappy, value: showControls)
    }

    private var legend: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                legendItem(color: .teal, title: "Interface", solid: true)
                legendItem(color: .green, title: "Direct", solid: true)
                legendItem(color: .blue, title: "Multi-hop", solid: false)
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding()
        }
    }

    private func nodeInspector(_ node: NetworkMapNode, availableWidth: CGFloat) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Image(systemName: node.symbolName).foregroundStyle(node.color)
                        Text(node.label).font(.headline)
                        Spacer()
                        Button("Close", systemImage: "xmark") { selectedNodeID = nil }.labelStyle(.iconOnly)
                    }
                    if let hash = node.destinationHash {
                        Text(hash).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Type", value: node.kind.displayName)
                    LabeledContent("State", value: node.status.displayName)
                    if let hops = node.hops { LabeledContent("Observed path", value: "\(hops) hop\(hops == 1 ? "" : "s")") }
                    if (node.kind == .destination || node.kind == .propagationNode), let hops = node.hops {
                        let unidentified = max(Int(hops) - 2, 0)
                        if unidentified > 0 {
                            LabeledContent(
                                "Intermediate identities",
                                value: "\(unidentified) not exposed by Reticulum"
                            )
                        }
                    }
                    if !node.detail.isEmpty { LabeledContent("Route", value: node.detail) }
                    if node.packetCount > 0 { LabeledContent("Packets observed", value: "\(node.packetCount)") }
                    if let lastSeen = node.lastSeen {
                        LabeledContent("Last observed", value: lastSeen.formatted(.relative(presentation: .named)))
                    }
                    if let hash = node.destinationHash, node.kind == .destination || node.kind == .propagationNode {
                        ViewThatFits {
                            HStack {
                                destinationActions(hash: hash, name: node.label)
                            }
                            VStack(alignment: .leading) {
                                destinationActions(hash: hash, name: node.label)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .font(.caption)
                .padding(14)
                .frame(width: min(360, max(220, availableWidth - 32)))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding()
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .animation(reduceMotion ? nil : .snappy, value: selectedNodeID)
    }

    @ViewBuilder
    private func destinationActions(hash: String, name: String) -> some View {
        Button("Open Chat", systemImage: "message") {
            openChat(hash: hash, name: name)
        }
        .buttonStyle(.borderedProminent)
        Button("Request Path", systemImage: "point.3.connected.trianglepath.dotted") {
            Task {
                await store.requestPath(to: hash)
                await refresh()
            }
        }
        .buttonStyle(.bordered)
        ShareLink(item: hash) {
            Label("Share ID", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
    }

    private func hoverCard(_ node: NetworkMapNode) -> some View {
        VStack {
            Spacer()
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.label).font(.caption.bold())
                    Text(node.detail.isEmpty ? node.kind.displayName : node.detail)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                Spacer()
            }
        }
        .padding()
        .allowsHitTesting(false)
    }

    private func metric(title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Text("\(value)").font(.title3.bold()).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }

    private func legendItem(color: Color, title: String, solid: Bool) -> some View {
        HStack(spacing: 5) {
            Path { path in path.move(to: .init(x: 0, y: 3)); path.addLine(to: .init(x: 18, y: 3)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: solid ? [] : [3, 3]))
                .frame(width: 18, height: 6)
            Text(title)
        }
    }

    private func screenPositions(in size: CGSize) -> [String: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return positions.mapValues { position in
            let base = CGPoint(x: position.x * size.width, y: position.y * size.height)
            return CGPoint(
                x: center.x + (base.x - center.x) * zoom + pan.width,
                y: center.y + (base.y - center.y) * zoom + pan.height
            )
        }
    }

    private func hitNode(at location: CGPoint, size: CGSize) -> NetworkMapNode? {
        let points = screenPositions(in: size)
        return filteredSnapshot.nodes
            .compactMap { node -> (NetworkMapNode, CGFloat)? in
                guard let point = points[node.id] else { return nil }
                return (node, hypot(point.x - location.x, point.y - location.y))
            }
            .filter { $0.1 <= 28 }
            .min { $0.1 < $1.1 }?.0
    }

    private func selectNode(at location: CGPoint, size: CGSize) {
        animate {
            selectedNodeID = hitNode(at: location, size: size)?.id
        }
    }

    private func resetViewport() {
        animate {
            zoom = 1
            pan = .zero
        }
    }

    private func animate(_ changes: () -> Void) {
        if reduceMotion { changes() }
        else { withAnimation(.snappy) { changes() } }
    }

    private func clearHiddenSelection() {
        guard let selectedNodeID,
              !filteredSnapshot.nodes.contains(where: { $0.id == selectedNodeID })
        else { return }
        self.selectedNodeID = nil
    }

    #if os(macOS)
    private func toggleFullScreen() {
        hostingWindow?.toggleFullScreen(nil)
    }
    #endif

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        snapshot = await store.networkMapSnapshot()
        if let selectedNodeID, !snapshot.nodes.contains(where: { $0.id == selectedNodeID }) {
            self.selectedNodeID = nil
        }
        isRefreshing = false
    }

    private func openChat(hash: String, name: String) {
        _ = store.addConversation(destinationHash: hash, displayName: name)
        store.selectedConversationID = store.conversations.first(where: { $0.destinationHash == hash })?.id
        dismiss()
    }
}

#if os(macOS)
private struct NetworkMapWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        resolveWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveWindow(for: nsView)
    }

    private func resolveWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onResolve(window)
        }
    }
}
#endif

private extension NetworkMapNode {
    var color: Color {
        switch kind {
        case .local: .indigo
        case .interface: status == .online ? .green : (status == .connecting ? .orange : .red)
        case .transport: .teal
        case .unidentifiedRelay: .gray
        case .destination: status == .offline ? .gray : .blue
        case .propagationNode: .purple
        }
    }

    var symbolName: String {
        switch kind {
        case .local: "network"
        case .interface: "arrow.left.arrow.right"
        case .transport: "point.3.connected.trianglepath.dotted"
        case .unidentifiedRelay: "questionmark"
        case .destination: "person.fill"
        case .propagationNode: "server.rack"
        }
    }
}

private extension NetworkMapNode.Kind {
    var displayName: String {
        switch self {
        case .local: "This Reticulum node"
        case .interface: "Network interface"
        case .transport: "Next-hop transport"
        case .unidentifiedRelay: "Unidentified relay position"
        case .destination: "LXMF destination"
        case .propagationNode: "LXMF propagation node"
        }
    }
}

private extension NetworkMapNode.Status {
    var displayName: String {
        switch self {
        case .online: "Online"
        case .connecting: "Connecting"
        case .stale: "Historical route"
        case .offline: "No current route"
        }
    }
}

private extension Color {
    static let networkMapBackground = Color(
        light: Color(red: 0.95, green: 0.96, blue: 0.98),
        dark: Color(red: 0.035, green: 0.04, blue: 0.055)
    )

    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}

private extension View {
    @ViewBuilder func platformNetworkMapSize() -> some View {
        #if os(macOS)
        frame(minWidth: 900, minHeight: 620)
        #else
        self
        #endif
    }
}
