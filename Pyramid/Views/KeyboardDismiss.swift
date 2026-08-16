import SwiftUI
import UIKit

private final class KeyboardDismisser {
    static let shared = KeyboardDismisser()
    private var attached = false

    func attachIfNeeded(to window: UIWindow) {
        guard !attached else { return }
        attached = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        window.addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: gesture.view)
        guard let hitView = gesture.view?.hitTest(location, with: nil) else { return }
        if hitView.isTextInput || hitView.isInsideTextInput { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private extension UIView {
    var isTextInput: Bool {
        self is UITextField || self is UITextView
    }

    var isInsideTextInput: Bool {
        var current = superview
        while let view = current {
            if view.isTextInput { return true }
            current = view.superview
        }
        return false
    }
}

extension View {
    func dismissKeyboardOnOutsideTap() -> some View {
        onAppear {
            DispatchQueue.main.async {
                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first,
                    let window = scene.windows.first else { return }
                KeyboardDismisser.shared.attachIfNeeded(to: window)
            }
        }
    }
}
