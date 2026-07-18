import RevenueCat
import SwiftUI

/// The one paywall screen, restyled by context. Onboarding shows only the two
/// yearly variants (7-day trial vs. $0.99 intro); everywhere else shows
/// monthly / yearly / lifetime. Presented as a sheet from contextual gates and
/// Settings, or embedded full-screen at the end of onboarding via `onClose`.
struct PaywallView: View {
    @Environment(PremiumStore.self) private var premium
    @Environment(\.dismiss) private var dismiss

    let context: PaywallContext
    /// Set when the paywall is embedded (onboarding) rather than presented;
    /// replaces the environment dismiss.
    var onClose: (() -> Void)?

    @State private var selectedPlanID: String?

    private var plans: [PaywallPlan] {
        context == .onboarding ? premium.onboardingPlans : premium.fullPlans
    }

    private var selectedPlan: PaywallPlan? {
        plans.first { $0.id == selectedPlanID } ?? plans.first { $0.badge != nil } ?? plans.first
    }

    var body: some View {
        @Bindable var premium = premium
        ZStack {
            SkyBackground(quiet: true)

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 18) {
                        GlassSurface(cornerRadius: 44) {
                            Image(systemName: "crown.fill")
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundStyle(Theme.Colors.lemon)
                                .frame(width: 88, height: 88)
                        }
                        .padding(.top, 6)

                        Text(context.headline)
                            .font(.system(size: 27, weight: .black, design: .rounded))
                            .multilineTextAlignment(.center)

                        Text(context.message)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.Colors.textDim)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 30)

                        if premium.isUnlocked {
                            unlockedCard
                        } else {
                            VStack(spacing: 10) {
                                ForEach(plans) { plan in
                                    PaywallPlanCard(
                                        plan: plan,
                                        selected: plan.id == selectedPlan?.id
                                    ) {
                                        selectedPlanID = plan.id
                                    }
                                }
                            }
                            .padding(.horizontal, 22)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)

                if !premium.isUnlocked {
                    footer
                }
            }
        }
        .foregroundStyle(Theme.Colors.ink)
        .onChange(of: premium.isUnlocked) { _, unlocked in
            if unlocked, context == .onboarding { close() }
        }
        .alert("Purchase issue", isPresented: Binding(
            get: { premium.purchaseError != nil },
            set: { if !$0 { premium.purchaseError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(premium.purchaseError ?? "")
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            if context != .onboarding {
                GlassIconButton(symbol: "xmark", accessibilityLabel: "Close paywall") { close() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var unlockedCard: some View {
        GlassSurface(cornerRadius: Theme.Radius.lg, tint: Theme.Colors.glassSelected) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 26, weight: .bold))
                Text("YOU'RE PREMIUM")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                    .tracking(1)
            }
            .padding(20)
        }
        .padding(.horizontal, 22)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            GlassTextButton(
                title: ctaTitle,
                disabled: premium.isPurchasing || selectedPlan?.package == nil
            ) {
                guard let plan = selectedPlan else { return }
                Task {
                    await premium.purchase(plan)
                    if premium.isUnlocked { close() }
                }
            }

            if !premium.storeIsLive {
                Text("APP STORE PRICING UNAVAILABLE RIGHT NOW")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Theme.Colors.textDim)
            }

            HStack(spacing: 18) {
                Button("Restore Purchases") {
                    Task {
                        if await premium.restore() { close() }
                    }
                }
                .font(.system(size: 13, weight: .bold))

                if context == .onboarding {
                    Button("Not now") { close() }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }

            Text("Subscriptions renew automatically until cancelled in App Store settings. Lifetime is a one-time purchase.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Colors.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
        }
        .padding(.bottom, 18)
    }

    private var ctaTitle: String {
        if premium.isPurchasing { return "CONTACTING APP STORE…" }
        switch selectedPlan?.kind {
        case .yearly: return "START 7-DAY FREE TRIAL"
        case .yearlyIntro: return "START FOR $0.99"
        case .lifetime: return "UNLOCK FOREVER"
        default: return "CONTINUE"
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

private struct PaywallPlanCard: View {
    let plan: PaywallPlan
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            GlassSurface(
                cornerRadius: Theme.Radius.md,
                tint: selected ? Theme.Colors.glassSelected : Theme.Colors.cream.opacity(0.16),
                interactive: true
            ) {
                HStack(spacing: 14) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selected ? Theme.Colors.ink : Theme.Colors.outline)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(plan.title)
                                .font(.system(size: 14, weight: .black, design: .rounded))
                                .tracking(1.2)
                            if let badge = plan.badge {
                                Text(badge)
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .tracking(0.8)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Theme.Colors.lemon, in: Capsule())
                            }
                        }
                        Text(plan.caption)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.textDim)
                    }

                    Spacer()

                    Text(plan.price)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("\(plan.title), \(plan.price), \(plan.caption)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    PaywallView(context: .general)
        .environment(PremiumStore())
}
