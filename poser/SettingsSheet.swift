import SwiftUI

enum ExportPreferences {
    static let includesPolaroidFrameKey = "includesPolaroidFrameInExports"
    static let autoSaveToCameraRollKey = "autoSaveToCameraRoll"
}

/// Settings borrows StyleSnap's easy-to-scan card rhythm while keeping POSER's
/// own fixed sky-and-glass visual language.
struct SettingsSheet: View {
    @AppStorage(ExportPreferences.includesPolaroidFrameKey) private var includesPolaroidFrame = false
    @AppStorage(ExportPreferences.autoSaveToCameraRollKey) private var autoSaveToCameraRoll = false
    @Environment(PremiumStore.self) private var premium
    @Environment(\.dismiss) private var dismiss

    @State private var showsPaywall = false
    @State private var restoreMessage: String?
    @State private var isRestoring = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(short) (\(build))"
    }

    var body: some View {
        @Bindable var premium = premium
        ZStack {
            SkyBackground(quiet: true)

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 12) {
                        Text("Choose how photos leave POSER and manage your Premium access.")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textDim)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        premiumCard
                        autoSaveCard
                        exportCard
                        restoreCard

#if DEBUG
                        SettingsCard(tint: Theme.Colors.cream.opacity(0.16)) {
                            Toggle(isOn: $premium.debugUnlocked) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("DEBUG PREMIUM UNLOCK")
                                        .font(.system(size: 12, weight: .black, design: .monospaced))
                                        .tracking(0.8)
                                    Text("Preview POSER with Premium active on this device.")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.Colors.textDim)
                                }
                            }
                            .tint(Theme.Colors.denim)
                        }
#endif

                        Text("POSER \(version)")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Theme.Colors.textDim)
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(Theme.Colors.ink)
        .sheet(isPresented: $showsPaywall) {
            PaywallView(context: .general)
        }
        .alert("Restore Purchases", isPresented: Binding(
            get: { restoreMessage != nil },
            set: { if !$0 { restoreMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(restoreMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("SETTINGS")
                .font(.system(size: 18, weight: .black, design: .rounded))
                .tracking(1.4)
            Spacer()
            GlassIconButton(symbol: "xmark", accessibilityLabel: "Close settings") { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    private var premiumCard: some View {
        SettingsCard(
            tint: premium.isUnlocked ? Theme.Colors.glassSelected : Theme.Colors.cream.opacity(0.2)
        ) {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: premium.isUnlocked ? "checkmark.seal.fill" : "sparkles")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(premium.isUnlocked ? Theme.Colors.denim : Theme.Colors.tangerine)
                        .frame(width: 40, height: 40)
                        .background(Theme.Colors.cream.opacity(0.55), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(premium.isUnlocked ? "PREMIUM ACTIVE" : "POSER PREMIUM")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .tracking(1)
                        Text(
                            premium.isUnlocked
                                ? "Unlimited poses and custom stickers."
                                : "Unlimited poses from Photos and custom cutout stickers."
                        )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !premium.isUnlocked {
                    GlassTextButton(title: "UPGRADE", compact: true) {
                        showsPaywall = true
                    }
                }
            }
        }
    }

    private var autoSaveCard: some View {
        SettingsCard(tint: Theme.Colors.sky.opacity(0.22)) {
            Toggle(isOn: $autoSaveToCameraRoll) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Theme.Colors.denim)
                        .frame(width: 40, height: 40)
                        .background(Theme.Colors.sky.opacity(0.52), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("AUTO-SAVE TO CAMERA ROLL")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .tracking(0.7)
                        Text("Automatically save each photo to your phone's library when you tap Done.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(Theme.Colors.denim)
            .accessibilityHint("Photos always stay in the POSER album regardless of this setting.")
        }
    }

    private var exportCard: some View {
        SettingsCard(tint: Theme.Colors.sky.opacity(0.22)) {
            Toggle(isOn: $includesPolaroidFrame) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Theme.Colors.denim)
                        .frame(width: 40, height: 40)
                        .background(Theme.Colors.sky.opacity(0.52), in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("SAVE WITH POLAROID FRAME")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .tracking(0.7)
                        Text("Add the album's white border and bottom space when you save or share a photo.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(Theme.Colors.denim)
            .accessibilityHint("Applies to future saves and shares. Photos inside the POSER album do not change.")
        }
    }

    private var restoreCard: some View {
        SettingsCard(tint: Theme.Colors.cream.opacity(0.14)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.Colors.denim)
                        .frame(width: 40, height: 40)
                        .background(Theme.Colors.cream.opacity(0.55), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RESTORE PURCHASES")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .tracking(0.7)
                        Text("Reconnect a previous App Store purchase.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                }

                GlassTextButton(
                    title: isRestoring ? "RESTORING…" : "RESTORE",
                    compact: true,
                    disabled: isRestoring
                ) {
                    restorePurchases()
                }
            }
        }
    }

    private func restorePurchases() {
        Task {
            isRestoring = true
            let restored = await premium.restore()
            isRestoring = false
            restoreMessage = restored
                ? "Premium restored. Welcome back!"
                : "No previous purchase was found for this Apple ID."
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        GlassSurface(cornerRadius: Theme.Radius.lg, tint: tint) {
            content
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    SettingsSheet()
        .environment(PremiumStore())
}
