import SwiftUI

struct SkyBackground: View {
    var quiet = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.white, Theme.Colors.bg, Theme.Colors.bgDeep],
                startPoint: .top,
                endPoint: .bottom
            )
            GeometryReader { proxy in
                CloudCluster(scale: 1.15)
                    .position(x: proxy.size.width * 0.08, y: proxy.size.height * 0.20)
                CloudCluster(scale: 0.72)
                    .position(x: proxy.size.width * 0.90, y: proxy.size.height * 0.42)
                CloudCluster(scale: 1.45)
                    .position(x: proxy.size.width * 0.42, y: proxy.size.height * 0.91)
            }
        }
        .opacity(quiet ? 0.55 : 1)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct CloudCluster: View {
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Color(red: 0.76, green: 0.84, blue: 0.92).opacity(0.16))
                .frame(width: 154, height: 34)
                .blur(radius: 10)
                .offset(y: 12)
            HStack(spacing: -22) {
                Circle().fill(.white.opacity(0.92)).frame(width: 74, height: 74)
                Circle().fill(.white).frame(width: 110, height: 110)
                Circle().fill(.white.opacity(0.94)).frame(width: 82, height: 82)
            }
            Capsule().fill(.white).frame(width: 198, height: 57)
        }
        .scaleEffect(scale)
        .shadow(color: Theme.stickerShadow, radius: 24, y: 8)
    }
}
