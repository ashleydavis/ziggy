import UIKit
import WebKit

// A web view that reports a change of the system's appearance while the app is in front.
public final class ZiggyWebView: WKWebView {
    // Called with the new style when the system's appearance changes while the app is in front.
    public var onSystemStyleChange: ((UIUserInterfaceStyle) -> Void)?

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard let previous = previousTraitCollection else {
            return
        }
        let style = traitCollection.userInterfaceStyle
        guard previous.userInterfaceStyle != style else {
            return
        }
        guard overrideUserInterfaceStyle == .unspecified, UIApplication.shared.applicationState == .active else {
            return
        }
        onSystemStyleChange?(style)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        window?.overrideUserInterfaceStyle = overrideUserInterfaceStyle
    }
}
