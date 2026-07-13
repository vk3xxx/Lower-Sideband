import SwiftUI
import SidebandCore

@main
struct SidebandApp: App {
    @State private var store = SidebandStore()

    @SceneBuilder
    var body: some Scene {
        #if os(macOS)
        WindowGroup("Sideband") { ContentView(store: store).frame(minWidth: 850, minHeight: 560) }
        .defaultSize(width: 1080, height: 720)
        #else
        WindowGroup("Sideband") { ContentView(store: store) }
        #endif
    }
}
