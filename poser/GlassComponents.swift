import SwiftUI
import UIKit

struct GlassSurface<Content: View>: View {
    private let shape: AnyShape
    let tint: Color
    let interactive: Bool
    @ViewBuilder let content: () -> Content

    init(
        cornerRadius: CGFloat = Theme.Radius.md,
        tint: Color = .clear,
        interactive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.shape = AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        self.tint = tint
        self.interactive = interactive
        self.content = content
    }

    /// For surfaces whose corners shouldn't all match - e.g. one end pinched
    /// tight to nest against an embedded image's own corner radius while the
    /// other stays a full pill cap.
    init(
        cornerRadii: RectangleCornerRadii,
        tint: Color = .clear,
        interactive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.shape = AnyShape(UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous))
        self.tint = tint
        self.interactive = interactive
        self.content = content
    }

    var body: some View {
        if #available(iOS 26, *) {
            if interactive {
                content()
                    .glassEffect(.clear.tint(tint).interactive(), in: shape)
            } else {
                content()
                    .glassEffect(.clear.tint(tint), in: shape)
            }
        } else {
            content()
                .background(.ultraThinMaterial)
                .background(Theme.Colors.glassFallback.opacity(0.38))
                .background(tint)
                .clipShape(shape)
                .overlay {
                    shape.stroke(Theme.Colors.glassEdge, lineWidth: 1)
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
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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

struct GhostOpacitySlider: View {
    @Binding var opacity: Double

    var body: some View {
        Slider(value: $opacity, in: 0.15...0.75)
            .controlSize(.small)
            .tint(Theme.Colors.sky)
            .accessibilityLabel("Ghost opacity")
            .accessibilityValue("\(Int(opacity * 100)) percent")
            .sensoryFeedback(.selection, trigger: opacity >= 0.40)
    }
}
