import Foundation
import Observation
import RevenueCat

/// Where a paywall was raised from. Drives the headline copy so the sheet
/// always names the limit the user just hit instead of a generic pitch.
enum PaywallContext: String, Identifiable {
    case onboarding
    case discover
    case poseLimit
    case stickerLimit
    case general

    var id: String { rawValue }

    var headline: String {
        switch self {
        case .onboarding: "GO PREMIUM"
        case .discover: "DISCOVER PREMIUM"
        case .poseLimit: "POSE LIMIT REACHED"
        case .stickerLimit: "STICKER LIMIT REACHED"
        case .general: "POSER PREMIUM"
        }
    }

    var message: String {
        switch self {
        case .onboarding, .discover, .general:
            "Unlimited poses from Photos and unlimited custom cutout stickers. The camera stays free forever."
        case .poseLimit:
            "Free includes \(PremiumStore.freePoseLimit) poses from Photos. Premium makes them unlimited — poses you've already added stay yours either way."
        case .stickerLimit:
            "Free includes \(PremiumStore.freeStickerLimit) custom cutout stickers. Premium makes them unlimited — stickers you've already made stay yours either way."
        }
    }
}

/// One purchasable plan as the paywall renders it. `package` is nil until
/// RevenueCat offerings load (or when the store is unconfigured), in which
/// case the fallback price strings below are shown and buying is disabled.
struct PaywallPlan: Identifiable {
    enum Kind: String {
        case monthly, yearly, yearlyIntro, lifetime
    }

    let kind: Kind
    let title: String
    let price: String
    let caption: String
    let badge: String?
    let package: Package?

    var id: String { kind.rawValue }
}

/// Single source of truth for the `premium` entitlement and the free-tier
/// limits, backed by RevenueCat.
///
/// Catalog (App Store Connect + RevenueCat, bundle `space.concurrent.poser`,
/// all attached to the one `premium` entitlement, offering `default`):
///   - `space.concurrent.poser.monthly`        $0.99/mo
///   - `space.concurrent.poser.yearly`         $9.99/yr, 7-day free trial
///   - `space.concurrent.poser.yearly_intro30` $9.99/yr, $0.99 first 30 days
///     (RevenueCat package identifier `yearly_intro30`)
///   - `space.concurrent.poser.lifetime`       $24.99 one-time
///
/// Free tier: 3 poses from Photos, 3 custom cutout stickers. Lapse never
/// deletes anything — records created while premium stay usable; only the
/// ability to create beyond the free limits goes away.
@MainActor
@Observable
final class PremiumStore {
    /// RevenueCat public Apple API key for `space.concurrent.poser`.
    /// Until it is filled in, the store runs "offline": paywalls render with
    /// the fallback catalog above and purchasing is disabled.
    private static let apiKey = "appl_REPLACE_WITH_POSER_PUBLIC_KEY"

    static let entitlementID = "premium"
    static let freePoseLimit = 3
    static let freeStickerLimit = 3
    static let yearlyIntroPackageID = "yearly_intro30"

    private(set) var isPremium = false
    private(set) var offerings: Offerings?
    private(set) var isPurchasing = false
    var purchaseError: String?

#if DEBUG
    /// Simulator/dev escape hatch: flips the entitlement without StoreKit so
    /// every gate can be exercised end-to-end. Debug builds only.
    var debugUnlocked = UserDefaults.standard.bool(forKey: "debugPremiumUnlocked") {
        didSet { UserDefaults.standard.set(debugUnlocked, forKey: "debugPremiumUnlocked") }
    }
#endif

    var isUnlocked: Bool {
#if DEBUG
        if debugUnlocked { return true }
#endif
        return isPremium
    }

    var storeIsLive: Bool { Purchases.isConfigured }

    init() {
        guard !Self.apiKey.contains("REPLACE") else { return }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: Self.apiKey)
        Task {
            for await info in Purchases.shared.customerInfoStream {
                apply(info)
            }
        }
        Task { await loadOfferings() }
    }

    func loadOfferings() async {
        guard storeIsLive else { return }
        offerings = try? await Purchases.shared.offerings()
    }

    func purchase(_ plan: PaywallPlan) async {
        guard let package = plan.package, !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if !result.userCancelled {
                apply(result.customerInfo)
            }
        } catch {
            purchaseError = Self.friendlyMessage(for: error)
        }
    }

    /// Returns whether restore found an active entitlement, so callers can
    /// tell "nothing to restore" apart from success.
    func restore() async -> Bool {
        guard storeIsLive else { return false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            return isPremium
        } catch {
            purchaseError = Self.friendlyMessage(for: error)
            return false
        }
    }

    // MARK: Gates

    func canAddCustomPose(currentCount: Int) -> Bool {
        isUnlocked || currentCount < Self.freePoseLimit
    }

    func canAddCustomSticker(currentCount: Int) -> Bool {
        isUnlocked || currentCount < Self.freeStickerLimit
    }

    // MARK: Plans

    /// Settings / contextual paywall: monthly, yearly (trial), lifetime.
    var fullPlans: [PaywallPlan] {
        [monthlyPlan, yearlyPlan, lifetimePlan]
    }

    /// Onboarding paywall: only the two yearly variants, mirroring StyleSnap —
    /// 7-day free trial vs. $0.99 first 30 days, same renewal price.
    var onboardingPlans: [PaywallPlan] {
        [yearlyPlan, yearlyIntroPlan]
    }

    private var current: Offering? { offerings?.current }

    private var monthlyPlan: PaywallPlan {
        PaywallPlan(
            kind: .monthly,
            title: "MONTHLY",
            price: current?.monthly?.storeProduct.localizedPriceString ?? "$0.99",
            caption: "per month",
            badge: nil,
            package: current?.monthly
        )
    }

    private var yearlyPlan: PaywallPlan {
        PaywallPlan(
            kind: .yearly,
            title: "YEARLY",
            price: current?.annual?.storeProduct.localizedPriceString ?? "$9.99",
            caption: "per year · 7-day free trial",
            badge: "BEST VALUE",
            package: current?.annual
        )
    }

    private var yearlyIntroPlan: PaywallPlan {
        let package = current?.package(identifier: Self.yearlyIntroPackageID)
        return PaywallPlan(
            kind: .yearlyIntro,
            title: "YEARLY",
            price: "$0.99",
            caption: "first 30 days, then \(package?.storeProduct.localizedPriceString ?? "$9.99")/year",
            badge: "INTRO OFFER",
            package: package
        )
    }

    private var lifetimePlan: PaywallPlan {
        PaywallPlan(
            kind: .lifetime,
            title: "LIFETIME",
            price: current?.lifetime?.storeProduct.localizedPriceString ?? "$24.99",
            caption: "one-time · yours forever",
            badge: nil,
            package: current?.lifetime
        )
    }

    // MARK: Private

    private func apply(_ info: CustomerInfo) {
        isPremium = info.entitlements[Self.entitlementID]?.isActive == true
    }

    /// RevenueCat error descriptions are developer-facing; users get copy that
    /// says what to do next and confirms they weren't charged.
    private static func friendlyMessage(for error: Error) -> String {
        switch (error as NSError).code {
        case ErrorCode.networkError.rawValue, ErrorCode.offlineConnectionError.rawValue:
            "The App Store couldn't be reached. Check your connection and try again."
        case ErrorCode.paymentPendingError.rawValue:
            "This purchase is waiting for approval. Premium unlocks as soon as it's confirmed."
        case ErrorCode.productAlreadyPurchasedError.rawValue:
            "You already own this — try Restore Purchases."
        default:
            "The purchase didn't go through and you haven't been charged. Please try again."
        }
    }
}
