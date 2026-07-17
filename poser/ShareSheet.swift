import SwiftUI
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

/// Hands a file to the system share sheet, presented by UIKit.
///
/// `UIActivityViewController` is built to be presented, not to be embedded as a
/// child of something else. Hosting it inside a SwiftUI `.sheet` made SwiftUI
/// animate an empty sheet up first and only let the controller start loading
/// once it was already on screen: 1.5s from tap to anything readable, most of it
/// spent staring at a blank sheet. Presented directly it is ~0.6s, nearly all of
/// which is the slide-up animation every share sheet plays, and the contents
/// ride up with it.
private struct ShareSheetPresenter: ViewModifier {
    @Binding var payload: SharePayload?

    func body(content: Content) -> some View {
        content.onChange(of: payload?.id) { _, id in
            guard id != nil, let url = payload?.url, let presenter = Self.topViewController() else { return }
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            // UIKit owns the dismissal, so without this the binding stays full
            // and the next share of the same photo looks like nothing happened.
            controller.completionWithItemsHandler = { _, _, _, _ in payload = nil }
            presenter.present(controller, animated: true)
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension View {
    /// Raises the system share sheet whenever `payload` is given a value.
    func shareSheet(payload: Binding<SharePayload?>) -> some View {
        modifier(ShareSheetPresenter(payload: payload))
    }
}
