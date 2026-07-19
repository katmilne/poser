import SwiftUI

/// One stop on a guided tour: an id matching a `.hintAnchor(_:)` tag elsewhere
/// in the view tree, plus the copy to show while that view is spotlighted.
struct HintStep: Identifiable {
    let id: String
    let title: String
    let message: String
}

private struct HintAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Registers this view's frame under `id` so `FeatureHintsOverlay` can spotlight it.
    func hintAnchor(_ id: String) -> some View {
        anchorPreference(key: HintAnchorKey.self, value: .bounds) { [id: $0] }
    }

    /// Collects every `.hintAnchor` frame beneath this view into `anchors`.
    func collectHintAnchors(into anchors: Binding<[String: Anchor<CGRect>]>) -> some View {
        onPreferenceChange(HintAnchorKey.self) { anchors.wrappedValue = $0 }
    }
}

/// A one-time, dismissible guided tour: dims the screen, cuts a spotlight hole
/// around the current step's anchored view, and shows a callout with
/// Skip/Next controls. Steps whose anchor never resolves (e.g. a control
/// hidden behind another sheet) are skipped automatically rather than
/// stalling the tour.
struct FeatureHintsOverlay: View {
    let steps: [HintStep]
    let anchors: [String: Anchor<CGRect>]
    let onFinish: () -> Void

    @State private var index = 0

    var body: some View {
        GeometryReader { proxy in
            if steps.indices.contains(index) {
                let step = steps[index]
                if let anchor = anchors[step.id] {
                    let rect = proxy[anchor]
                    ZStack {
                        SpotlightMask(hole: rect)
                            .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture(perform: advance)

                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.9), lineWidth: 2)
                            .frame(width: rect.width + 16, height: rect.height + 16)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)

                        callout(for: step, near: rect, in: proxy.size)
                    }
                    .transition(.opacity)
                } else {
                    // Anchor not laid out yet (or never will be) — move on
                    // instead of leaving a full-screen dim with nothing lit.
                    Color.clear.onAppear(perform: advance)
                }
            }
        }
        .animation(.poserGlide, value: index)
    }

    private func callout(for step: HintStep, near rect: CGRect, in screen: CGSize) -> some View {
        let showsBelow = rect.midY < screen.height * 0.62
        let width = min(280, screen.width - 40)
        return GlassSurface(cornerRadius: Theme.Radius.md, tint: Theme.Colors.cream.opacity(0.95)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(step.title)
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .tracking(0.6)
                Text(step.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Skip", action: onFinish)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Colors.textDim)

                    Spacer()

                    Text("\(index + 1)/\(steps.count)")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textDim)

                    Spacer()

                    Button(index == steps.count - 1 ? "Got it" : "Next", action: advance)
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(Theme.Colors.ink)
                }
            }
            .padding(16)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width)
        .position(
            x: min(max(rect.midX, width / 2 + 16), screen.width - width / 2 - 16),
            y: showsBelow
                ? min(rect.maxY + 96, screen.height - 70)
                : max(rect.minY - 96, 70)
        )
    }

    private func advance() {
        if index < steps.count - 1 {
            index += 1
        } else {
            onFinish()
        }
    }
}

/// A full-screen rect with a rounded-rect hole punched out of it. Paired with
/// an even-odd fill, everything except `hole` gets dimmed.
private struct SpotlightMask: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let padded = hole.insetBy(dx: -8, dy: -8)
        path.addRoundedRect(in: padded, cornerSize: CGSize(width: 16, height: 16))
        return path
    }
}
