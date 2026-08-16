import SwiftUI

@main
struct PyramidApp: App {
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
        }
    }
}
