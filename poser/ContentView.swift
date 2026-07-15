import SwiftData
import SwiftUI

struct ContentView: View {
    @AppStorage("onboarded") private var onboarded = false
    @Environment(AppState.self) private var appState
    @State private var camera = CameraController()

    var body: some View {
        @Bindable var appState = appState
        Group {
            if onboarded {
                CameraView(camera: camera)
            } else {
                OnboardingView {
                    onboarded = true
                }
            }
        }
        .accessibilityHidden(
            appState.showsGallery || appState.showsPoseLibrary ||
            appState.presentedShot != nil || appState.editingShot != nil
        )
        .fullScreenCover(isPresented: $appState.showsGallery) {
            GalleryView()
        }
        .sheet(isPresented: $appState.showsPoseLibrary) {
            PoseLibraryView()
        }
        .fullScreenCover(item: $appState.presentedShot) { shot in
            PreviewEditorView(shot: shot)
        }
        .fullScreenCover(item: $appState.editingShot) { shot in
            PreviewEditorView(shot: shot)
        }
        .task {
            try? await ImageStore.shared.prepareDirectories()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .modelContainer(for: [ShotRecord.self, OverlayRecord.self, CustomStickerRecord.self], inMemory: true)
}
