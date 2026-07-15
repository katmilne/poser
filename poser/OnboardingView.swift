import AVFoundation
import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void
    @State private var page = 0

    private let slides = [
        OnboardingSlide(
            symbol: "photo.on.rectangle.angled",
            title: "Match the pose.",
            body: "Choose a reference photo. It floats over the camera so anyone can line up the shot."
        ),
        OnboardingSlide(
            symbol: "camera.aperture",
            title: "Clean photos, always.",
            body: "The guide disappears before capture. Your full-resolution photo stays clean and on your phone."
        )
    ]

    var body: some View {
        ZStack {
            SkyBackground()
            VStack(spacing: 0) {
                Text("Poser")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.top, 30)

                TabView(selection: $page) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        VStack(spacing: 24) {
                            GlassSurface(cornerRadius: 56) {
                                Image(systemName: slide.symbol)
                                    .font(.system(size: 54, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(Theme.Colors.denim)
                                    .frame(width: 112, height: 112)
                            }
                            Text(slide.title)
                                .font(.system(size: 34, weight: .black, design: .rounded))
                                .multilineTextAlignment(.center)
                            Text(slide.body)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Theme.Colors.textDim)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .padding(.horizontal, 36)
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 8) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, _ in
                        Capsule()
                            .fill(index == page ? Theme.Colors.ink : Theme.Colors.outline)
                            .frame(width: index == page ? 26 : 8, height: 8)
                            .animation(.easeOut(duration: 0.22), value: page)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(page + 1) of \(slides.count)")
                .padding(.bottom, 20)

                GlassTextButton(title: page == slides.count - 1 ? "ALLOW CAMERA" : "CONTINUE") {
                    if page < slides.count - 1 {
                        withAnimation(.poserGlide) { page += 1 }
                    } else {
                        Task {
#if !targetEnvironment(simulator)
                            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                                _ = await AVCaptureDevice.requestAccess(for: .video)
                            }
#endif
                            onComplete()
                        }
                    }
                }
                .padding(.bottom, 36)
            }
        }
        .foregroundStyle(Theme.Colors.ink)
    }
}

private struct OnboardingSlide {
    let symbol: String
    let title: String
    let body: String
}
