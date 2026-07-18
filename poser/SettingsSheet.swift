import SwiftUI

/// Small settings sheet opened from the POSER chip on the camera screen.
/// Mostly exists to give Premium a stable home: status, upgrade, restore.
struct SettingsSheet: View {
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

            VStack(spacing: 16) {
                HStack {
                    Text("SETTINGS")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .tracking(1.4)
                    Spacer()
                    GlassIconButton(symbol: "xmark", accessibilityLabel: "Close settings") { dismiss() }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)

                GlassSurface(
                    cornerRadius: Theme.Radius.lg,
                    tint: premium.isUnlocked ? Theme.Colors.glassSelected : Theme.Colors.cream.opacity(0.2)
                ) {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Image(systemName: premium.isUnlocked ? "checkmark.seal.fill" : "crown.fill")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(premium.isUnlocked ? Theme.Colors.ink : Theme.Colors.lemon)
                            VStack(alignment: .leading, spacing: 2) {
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
                            Spacer()
                        }
                        if !premium.isUnlocked {
                            GlassTextButton(title: "UPGRADE", compact: true) {
                                showsPaywall = true
                            }
                        }
                    }
                    .padding(16)
                }
                .padding(.horizontal, 20)

                GlassTextButton(
                    title: isRestoring ? "RESTORING…" : "RESTORE PURCHASES",
                    compact: true,
                    disabled: isRestoring
                ) {
                    Task {
                        isRestoring = true
                        let restored = await premium.restore()
                        isRestoring = false
                        restoreMessage = restored
                            ? "Premium restored. Welcome back!"
                            : "No previous purchase was found for this Apple ID."
                    }
                }

#if DEBUG
                GlassSurface(cornerRadius: Theme.Radius.md, tint: Theme.Colors.cream.opacity(0.16)) {
                    Toggle(isOn: $premium.debugUnlocked) {
                        Text("DEBUG PREMIUM UNLOCK")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .tracking(0.8)
                    }
                    .tint(Theme.Colors.denim)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .padding(.horizontal, 20)
#endif

                Spacer()

                Text("POSER \(version)")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Theme.Colors.textDim)
                    .padding(.bottom, 16)
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
}

#Preview {
    SettingsSheet()
        .environment(PremiumStore())
}
