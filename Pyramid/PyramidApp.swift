import SwiftUI

@main
struct PyramidApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = ChatStore()
    @StateObject private var worldBook = WorldBookStore()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, store: store, worldBook: worldBook)
        }
    }
}
