import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Text("Pyramid")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("iOS 空壳工程 · v0.1")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
