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
                    VStack(spacing: context == .onboarding ? 14 : 12) {
                        GlassSurface(cornerRadius: 44) {
                            Image(systemName: "sparkles")
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

                        PaywallBenefitList(compact: context != .onboarding)

                        if premium.isUnlocked {
                            unlockedCard
                        } else {
                            if context == .onboarding, let selectedPlan {
                                PaywallOfferTimeline(plan: selectedPlan)
                            }

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
                    .padding(.bottom, context == .onboarding ? 24 : 16)
                }
                .scrollIndicators(.hidden)

                if !premium.isUnlocked {
                    footer
                }
            }
        }
        .foregroundStyle(Theme.Colors.ink)
        .task {
            Analytics.track("paywall_shown", ["context": context.rawValue])
            await premium.loadOfferings()
        }
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
            GlassIconButton(symbol: "xmark", accessibilityLabel: "Close paywall") { close() }
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
        VStack(spacing: context == .onboarding ? 12 : 8) {
            purchaseButton
            purchaseDetails
        }
        .padding(.bottom, context == .onboarding ? 18 : 10)
    }

    private var purchaseButton: some View {
        PaywallPurchaseButton(
            title: ctaTitle,
            disabled: premium.isPurchasing || selectedPlan?.package == nil
        ) {
            guard let plan = selectedPlan else { return }
            Task {
                await premium.purchase(plan)
                if premium.isUnlocked { close() }
            }
        }
    }

    @ViewBuilder
    private var purchaseDetails: some View {
        VStack(spacing: context == .onboarding ? 12 : 8) {
            if premium.isLoadingOfferings {
                ProgressView()
                    .tint(Theme.Colors.ink)
                    .accessibilityLabel("Loading App Store pricing")
            } else if selectedPlan?.package == nil {
                Button {
                    Task { await premium.loadOfferings() }
                } label: {
                    Text("APP STORE PRICING UNAVAILABLE · RETRY")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .accessibilityHint("Attempts to reload plans and prices")
            }

            Text(selectedPlanDisclosure)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Colors.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

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

            Text(legalText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Colors.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
        }
    }

    private var ctaTitle: String {
        if premium.isPurchasing { return "CONTACTING APP STORE…" }
        return selectedPlan?.ctaTitle ?? "CONTINUE"
    }

    private var legalText: String {
        if context == .onboarding {
            return "Yearly subscriptions renew automatically until cancelled in App Store settings. Introductory offers are limited to eligible customers."
        }
        return "Subscriptions renew automatically until cancelled in App Store settings. Lifetime is a one-time purchase. Introductory offers are limited to eligible customers."
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var selectedPlanDisclosure: String {
        guard let plan = selectedPlan else { return "Select a plan to see its billing details." }
        switch plan.kind {
        case .monthly:
            return "\(plan.price) per month. Renews monthly until cancelled."
        case .yearly, .yearlyIntro:
            if plan.caption == "per year" {
                return "\(plan.price) per year. Renews yearly until cancelled."
            }
            if plan.kind == .yearlyIntro {
                return "\(plan.price) \(plan.caption). Renews yearly until cancelled."
            }
            return "\(plan.caption). Renews yearly until cancelled."
        case .lifetime:
            return "\(plan.price) one-time purchase. No subscription."
        }
    }
}

private struct PaywallBenefit: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String
    let tint: Color
}

private struct PaywallBenefitList: View {
    let compact: Bool

    private static let benefits = [
        PaywallBenefit(
            id: "poses",
            symbol: "photo.stack.fill",
            title: "UNLIMITED PHOTO POSES",
            detail: "Save every reference pose you want from Photos.",
            tint: Theme.Colors.cyan.opacity(0.72)
        ),
        PaywallBenefit(
            id: "stickers",
            symbol: "wand.and.stars",
            title: "UNLIMITED CUTOUT STICKERS",
            detail: "Turn more photos into custom stickers for your shots.",
            tint: Theme.Colors.lemon.opacity(0.82)
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT PREMIUM UNLOCKS")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.2)
                .padding(.leading, 2)

            if compact {
                HStack(spacing: 8) {
                    ForEach(Self.benefits) { benefit in
                        PaywallBenefitChip(benefit: benefit)
                    }
                }
            } else {
                ForEach(Self.benefits) { benefit in
                    PaywallBenefitRow(benefit: benefit)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }
}

private struct PaywallBenefitRow: View {
    let benefit: PaywallBenefit

    var body: some View {
        HStack(spacing: 12) {
            GlassSurface(cornerRadius: 18, tint: benefit.tint) {
                Image(systemName: benefit.symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.Colors.denim)
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(0.7)
                Text(benefit.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PaywallBenefitChip: View {
    let benefit: PaywallBenefit

    var body: some View {
        GlassSurface(cornerRadius: Theme.Radius.md, tint: benefit.tint) {
            HStack(spacing: 7) {
                Image(systemName: benefit.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Colors.denim)
                    .accessibilityHidden(true)
                Text(benefit.title)
                    .font(.system(size: 9.5, weight: .black, design: .rounded))
                    .tracking(0.45)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(benefit.title). \(benefit.detail)")
    }
}

private struct PaywallOfferTimeline: View {
    let plan: PaywallPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("YOUR PREMIUM START")
                .font(.system(size: 11, weight: .black, design: .monospaced))
                .tracking(1.2)
                .padding(.leading, 2)

            timelineRow(
                symbol: "lock.open.fill",
                title: "LIMITS LIFT RIGHT AWAY",
                detail: "Your pose and sticker limits disappear immediately."
            )
            timelineRow(
                symbol: "creditcard.fill",
                title: billingTitle,
                detail: billingDetail
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }

    private func timelineRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            GlassSurface(cornerRadius: 16, tint: Theme.Colors.grape.opacity(0.58)) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Colors.denim)
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(0.7)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var billingTitle: String {
        if plan.kind == .yearly, plan.caption.hasPrefix("7 days free") {
            return "BILLING STARTS AFTER 7 DAYS"
        }
        if plan.kind == .yearlyIntro, plan.caption.hasPrefix("for the first month") {
            return "INTRO PRICE FOR THE FIRST MONTH"
        }
        return "BILLED YEARLY"
    }

    private var billingDetail: String {
        if plan.caption == "per year" {
            return "\(plan.price) per year. Cancel anytime."
        }
        if plan.kind == .yearlyIntro {
            return "\(plan.price) \(plan.caption). Cancel anytime."
        }
        return "\(plan.caption). Cancel anytime."
    }
}

private struct PaywallPurchaseButton: View {
    let title: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassSurface(
                cornerRadius: Theme.Radius.pill,
                tint: disabled ? .clear : Theme.Colors.glassSelectedStrong,
                interactive: true
            ) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .black))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .tracking(0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
                .foregroundStyle(disabled ? Theme.Colors.disabled : Theme.Colors.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(disabled)
        .padding(.horizontal, 22)
        .accessibilityLabel(title)
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
                interactive: false
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
                .contentShape(.rect)
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(Theme.Colors.denim.opacity(0.68), lineWidth: 2)
                }
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("\(plan.title), \(plan.price), \(plan.caption)")
        .accessibilityHint("Double-tap to select this plan")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#Preview {
    PaywallView(context: .general)
        .environment(PremiumStore())
}
