import SwiftUI

@main
struct PyramidApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, store: store)
        }
    }
}
