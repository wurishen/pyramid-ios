import Foundation
import SwiftUI

final class AppSettings: ObservableObject {
    @AppStorage("apiBaseURL") var baseURL = ""
    @AppStorage("apiKey") var apiKey = ""
    @AppStorage("modelName") var modelName = ""
    @AppStorage("useStreaming") var useStreaming = true
}
