import SwiftUI
import UIKit

public struct WindowSceneTitleModifier: ViewModifier {
    public let title: String
    public var onWindowChange: ((UIWindow?) -> Void)?

    public func body(content: Content) -> some View {
        content.background(
            WindowSceneTitleAccessor(title: title, onWindowChange: onWindowChange)
                .allowsHitTesting(false)
        )
    }
}

public extension View {
    func windowSceneTitle(_ title: String, onWindowChange: ((UIWindow?) -> Void)? = nil) -> some View {
        modifier(WindowSceneTitleModifier(title: title, onWindowChange: onWindowChange))
    }
}

struct WindowSceneTitleAccessor: UIViewRepresentable {
    let title: String
    var onWindowChange: ((UIWindow?) -> Void)?

    func makeUIView(context: Context) -> WindowTitleUIView {
        let view = WindowTitleUIView()
        view.targetTitle = title
        view.onWindowChange = onWindowChange
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: WindowTitleUIView, context: Context) {
        uiView.targetTitle = title
        uiView.onWindowChange = onWindowChange
        uiView.updateTitle()
    }
}

final class WindowTitleUIView: UIView {
    var targetTitle: String = "" {
        didSet {
            updateTitle()
        }
    }
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
        updateTitle()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onWindowChange?(self.window)
                self.updateTitle()
            }
        }
    }

    func updateTitle() {
        guard !targetTitle.isEmpty, let windowScene = window?.windowScene else { return }
        if windowScene.title != targetTitle {
            windowScene.title = targetTitle
        }
    }
}
