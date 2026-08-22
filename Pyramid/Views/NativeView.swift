import SwiftUI

// Minimal NativeView for build error isolation
struct NativeView: View {
    let node: NativeIRNode
    var body: some View {
        Text("placeholder")
    }
}
