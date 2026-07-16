import SwiftUI
import UIKit

struct GlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let tint: Color
    let interactive: Bool
    @ViewBuilder let content: () -> Content

    init(
        cornerRadius: CGFloat = Theme.Radius.md,
        tint: Color = .clear,
        interactive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.interactive = interactive
        self.content = content
    }

    var body: some View {
        if #available(iOS 26, *) {
            if interactive {
                content()
                    .glassEffect(
                        .clear.tint(tint).interactive(),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            } else {
                content()
                    .glassEffect(
                        .clear.tint(tint),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }
        } else {
            content()
                .background(.ultraThinMaterial)
                .background(Theme.Colors.glassFallback.opacity(0.38))
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Theme.Colors.glassEdge, lineWidth: 1)
                }
                .shadow(color: Theme.charmShadow, radius: 12, y: 3)
        }
    }
}

struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

struct GlassIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    var size: CGFloat = 46
    var selected = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassSurface(
                cornerRadius: size / 2,
                tint: selected ? Theme.Colors.glassSelected : .clear,
                interactive: true
            ) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.43, weight: .semibold))
                    .foregroundStyle(disabled ? Theme.Colors.disabled : Theme.Colors.ink)
                    .frame(width: size, height: size)
                    .contentShape(.circle)
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct GlassTextButton: View {
    let title: String
    var compact = false
    var selected = false
    var disabled = false
    /// Floor for the pill's width. A row of these otherwise sizes each pill to
    /// its own label, so set this to give a set of related choices one width.
    var minWidth: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassSurface(
                cornerRadius: Theme.Radius.pill,
                tint: selected ? Theme.Colors.glassSelectedStrong : .clear,
                interactive: true
            ) {
                Text(title)
                    .font(.system(size: compact ? 13 : 15, weight: selected ? .heavy : .bold))
                    .tracking(0.4)
                    .foregroundStyle(disabled ? Theme.Colors.disabled : Theme.Colors.ink)
                    .padding(.horizontal, compact ? 14 : 20)
                    .frame(minWidth: minWidth)
                    .frame(height: compact ? 36 : 48)
            }
            .overlay {
                if selected {
                    Capsule(style: .continuous)
                        .strokeBorder(Theme.Colors.glassSelectedEdge, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(disabled)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .sensoryFeedback(.selection, trigger: selected)
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostOpacityBar: View {
    @Binding var opacity: Double
    @State private var crossedDetent = false

    var body: some View {
        GeometryReader { proxy in
            let progress = (opacity - 0.15) / 0.60
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28))
                Capsule()
                    .fill(Theme.Colors.ink.opacity(0.28))
                    .frame(width: max(7, proxy.size.width * progress))
                Capsule()
                    .fill(.white.opacity(0.95))
                    .frame(width: 2)
                    .offset(x: max(3, proxy.size.width * progress - 1))
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let next = min(0.75, max(0.15, 0.15 + 0.60 * value.location.x / proxy.size.width))
                        let isAbove = next >= 0.40
                        if isAbove != crossedDetent {
                            UISelectionFeedbackGenerator().selectionChanged()
                            crossedDetent = isAbove
                        }
                        opacity = next
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Ghost opacity")
            .accessibilityValue("\(Int(opacity * 100)) percent")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: opacity = min(0.75, opacity + 0.05)
                case .decrement: opacity = max(0.15, opacity - 0.05)
                @unknown default: break
                }
            }
        }
        .frame(height: 14)
    }
}
