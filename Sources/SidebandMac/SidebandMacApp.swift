import SwiftUI
import SidebandCore

@main
struct SidebandMacApp: App {
    @State private var store = SidebandStore()

    var body: some Scene {
        WindowGroup("Sideband") { ContentView(store: store).frame(minWidth: 850, minHeight: 560) }
        .defaultSize(width: 1080, height: 720)
    }
}
