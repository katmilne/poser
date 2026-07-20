import Foundation
import Observation
import RevenueCat

/// Where a paywall was raised from. Drives the headline copy so the sheet
/// always names the limit the user just hit instead of a generic pitch.
enum PaywallContext: String, Identifiable {
    case onboarding
    case discover
    case poseLimit
    case premiumPose
    case stickerLimit
    case general

    var id: String { rawValue }

    var headline: String {
        switch self {
        case .onboarding: "GO PREMIUM"
        case .discover: "DISCOVER PREMIUM"
        case .poseLimit: "POSE LIMIT REACHED"
        case .premiumPose: "PREMIUM POSE"
        case .stickerLimit: "STICKER LIMIT REACHED"
        case .general: "POSER PREMIUM"
        }
    }

    var message: String {
        switch self {
        case .onboarding, .discover, .general:
            "The whole pose collection, unlimited poses from Photos, and unlimited custom cutout stickers. The camera stays free forever."
        case .poseLimit:
            "Free includes \(PremiumStore.freePoseLimit) poses from Photos. Premium makes them unlimited - poses you've already added stay yours either way."
        case .premiumPose:
            "This one is part of the Premium collection. Unlock it and every other premium pose, plus unlimited poses from Photos and unlimited cutout stickers."
        case .stickerLimit:
            "Free includes \(PremiumStore.freeStickerLimit) custom cutout stickers. Premium makes them unlimited - stickers you've already made stay yours either way."
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
    let ctaTitle: String
    let package: Package?

    var id: String { kind.rawValue }
}

/// Single source of truth for the `premium` entitlement and the free-tier
/// limits, backed by RevenueCat.
///
/// Catalog (App Store Connect + RevenueCat, bundle `space.concurrent.poser`,
/// all attached to the one `premium` entitlement):
///   - `space.concurrent.poser.monthly`        $1.99/mo
///   - `space.concurrent.poser.yearly`         $9.99/yr, 7-day free trial
///   - `space.concurrent.poser.yearly_intro30` $9.99/yr, $0.99 first 30 days
///   - `space.concurrent.poser.lifetime`       $14.99 one-time
///
/// Offering `onboarding` contains custom packages `annual_7_day_trial` and
/// `annual_intro_30_day`. The in-app paywall uses RevenueCat's current
/// offering, falling back to offering `default`.
///
/// Free tier: the free half of the bundled pose collection, 3 poses from
/// Photos, 3 custom cutout stickers. Lapse never deletes anything - records
/// created while premium stay usable; only the ability to create beyond the
/// free limits, and access to the premium half of the collection, goes away.
@MainActor
@Observable
final class PremiumStore {
    /// Kept out of source control - see `Secrets.swift.example`. Until it is
    /// filled in, the store runs "offline": paywalls render with the fallback
    /// catalog above and purchasing is disabled.
    private static let apiKey = Secrets.revenueCatAPIKey

    static let entitlementID = "premium"
    static let freePoseLimit = 3
    static let freeStickerLimit = 3
    static let onboardingOfferingID = "onboarding"
    static let defaultOfferingID = "default"
    static let onboardingTrialPackageID = "annual_7_day_trial"
    static let onboardingIntroPackageID = "annual_intro_30_day"

    private static let monthlyProductID = "space.concurrent.poser.monthly"
    private static let yearlyProductID = "space.concurrent.poser.yearly"
    private static let yearlyIntroProductID = "space.concurrent.poser.yearly_intro30"
    private static let lifetimeProductID = "space.concurrent.poser.lifetime"

    private(set) var isPremium = false
    private(set) var offerings: Offerings?
    private(set) var isLoadingOfferings = false
    private(set) var isPurchasing = false
    private(set) var introEligibility: [String: IntroEligibilityStatus] = [:]
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
        guard Self.apiKey.hasPrefix("appl_"), !Self.apiKey.contains("REPLACE") else { return }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: Self.apiKey)
        Task {
            for await info in Purchases.shared.customerInfoStream {
                apply(info)
            }
        }
        Task {
            await refreshCustomerInfo()
            await loadOfferings()
        }
    }

    func loadOfferings() async {
        guard storeIsLive, !isLoadingOfferings else { return }
        isLoadingOfferings = true
        // Never carry a previous eligibility result into a newly presented
        // paywall. Offer terms stay hidden until this customer's fresh check
        // completes; `.unknown` and `.ineligible` both use regular pricing.
        introEligibility = [:]
        defer { isLoadingOfferings = false }

        do {
            let loaded = try await Purchases.shared.offerings()
            offerings = loaded

            let packages = [
                validatedPackage(
                    loaded.all[Self.onboardingOfferingID]?.package(identifier: Self.onboardingTrialPackageID),
                    productID: Self.yearlyProductID
                ),
                validatedPackage(
                    loaded.all[Self.onboardingOfferingID]?.package(identifier: Self.onboardingIntroPackageID),
                    productID: Self.yearlyIntroProductID
                ),
                validatedPackage(generalOffering(from: loaded)?.annual, productID: Self.yearlyProductID)
            ].compactMap { $0 }
            let productIDs = Array(Set(packages.map(\.storeProduct.productIdentifier)))
            if productIDs.isEmpty {
                introEligibility = [:]
            } else {
                let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
                    productIdentifiers: productIDs
                )
                introEligibility = eligibility.mapValues(\.status)
            }
        } catch {
            offerings = nil
            introEligibility = [:]
        }
    }

    func purchase(_ plan: PaywallPlan) async {
        guard let package = plan.package, !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        Analytics.track("purchase_started", ["plan": plan.kind.rawValue])
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                Analytics.track("purchase_cancelled", ["plan": plan.kind.rawValue])
            } else {
                apply(result.customerInfo)
                if isPremium {
                    Analytics.track("purchase_completed", ["plan": plan.kind.rawValue])
                } else {
                    purchaseError = "The App Store completed the purchase, but Premium is not active yet. Try Restore Purchases in a moment."
                }
            }
        } catch {
            purchaseError = Self.friendlyMessage(for: error)
            Analytics.captureError(error, area: "purchase")
        }
    }

    /// Returns whether restore found an active entitlement, so callers can
    /// tell "nothing to restore" apart from success.
    func restore() async -> Bool {
        guard storeIsLive else { return false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            if isPremium { Analytics.track("purchase_restored") }
            return isPremium
        } catch {
            purchaseError = Self.friendlyMessage(for: error)
            Analytics.captureError(error, area: "restore_purchase")
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

    /// Premium poses are seeded onto every device so the library can show them
    /// as a preview, so "locked" is purely a display-and-selection state - it
    /// never means the pose is absent. Poses the user added from Photos are
    /// always theirs, including ones imported while premium was active.
    func isLocked(_ overlay: OverlayRecord) -> Bool {
        !isUnlocked && overlay.isPremiumPose
    }

    // MARK: Plans

    /// Settings / contextual paywall: monthly, yearly (trial), lifetime.
    var fullPlans: [PaywallPlan] {
        [monthlyPlan, generalYearlyPlan, lifetimePlan]
    }

    /// Onboarding paywall: only introductory offers that RevenueCat has
    /// confirmed this App Store customer can redeem. If neither offer is
    /// eligible (including while eligibility is unknown), keep one ordinary
    /// yearly option available without introductory pricing or trial copy.
    var onboardingPlans: [PaywallPlan] {
        let trial = onboardingTrialPlan
        let discountedMonth = onboardingIntroPlan
        let eligibleOffers = [trial, discountedMonth].filter {
            isEligibleForIntroOffer($0.package)
        }

        return eligibleOffers.isEmpty ? [trial] : eligibleOffers
    }

    private var onboardingOffering: Offering? {
        offerings?.all[Self.onboardingOfferingID]
    }

    private var generalOffering: Offering? {
        guard let offerings else { return nil }
        return generalOffering(from: offerings)
    }

    private var monthlyPlan: PaywallPlan {
        let package = validatedPackage(generalOffering?.monthly, productID: Self.monthlyProductID)
        return PaywallPlan(
            kind: .monthly,
            title: "MONTHLY",
            price: package?.storeProduct.localizedPriceString ?? "$1.99",
            caption: "per month",
            badge: nil,
            ctaTitle: "CHOOSE MONTHLY",
            package: package
        )
    }

    private var generalYearlyPlan: PaywallPlan {
        let package = validatedPackage(generalOffering?.annual, productID: Self.yearlyProductID)
        let price = package?.storeProduct.localizedPriceString ?? "$9.99"
        let eligible = isEligibleForIntroOffer(package)
        return PaywallPlan(
            kind: .yearly,
            title: "YEARLY",
            price: price,
            caption: eligible ? "7 days free, then \(price)/year" : "per year",
            badge: annualSavingsBadge,
            ctaTitle: eligible ? "START 7-DAY FREE TRIAL" : "CHOOSE YEARLY",
            package: package
        )
    }

    /// Uses the customer's real App Store prices so the savings claim remains
    /// truthful across currencies and regional price tiers. Until offerings
    /// load, the existing neutral badge remains in place.
    private var annualSavingsBadge: String {
        guard
            let monthly = validatedPackage(generalOffering?.monthly, productID: Self.monthlyProductID),
            let yearly = validatedPackage(generalOffering?.annual, productID: Self.yearlyProductID)
        else { return "BEST VALUE" }

        let monthlyForYear = monthly.storeProduct.price * 12
        guard monthlyForYear > 0 else { return "BEST VALUE" }

        let ratio = NSDecimalNumber(decimal: yearly.storeProduct.price)
            .dividing(by: NSDecimalNumber(decimal: monthlyForYear))
            .doubleValue
        let savings = Int(((1 - ratio) * 100).rounded())
        return savings > 0 ? "SAVE \(savings)%" : "BEST VALUE"
    }

    private var onboardingTrialPlan: PaywallPlan {
        let package = validatedPackage(
            onboardingOffering?.package(identifier: Self.onboardingTrialPackageID),
            productID: Self.yearlyProductID
        )
        let price = package?.storeProduct.localizedPriceString ?? "$9.99"
        let eligible = isEligibleForIntroOffer(package)
        return PaywallPlan(
            kind: .yearly,
            title: "YEARLY",
            price: price,
            caption: eligible ? "7 days free, then \(price)/year" : "per year",
            badge: eligible ? "7 DAYS FREE" : nil,
            ctaTitle: eligible ? "START 7-DAY FREE TRIAL" : "CHOOSE YEARLY",
            package: package
        )
    }

    private var onboardingIntroPlan: PaywallPlan {
        let package = validatedPackage(
            onboardingOffering?.package(identifier: Self.onboardingIntroPackageID),
            productID: Self.yearlyIntroProductID
        )
        let renewalPrice = package?.storeProduct.localizedPriceString ?? "$9.99"
        let eligible = isEligibleForIntroOffer(package)
        let introductoryPrice = package?.localizedIntroductoryPriceString ?? "$0.99"
        return PaywallPlan(
            kind: .yearlyIntro,
            title: "YEARLY",
            price: eligible ? introductoryPrice : renewalPrice,
            caption: eligible
                ? "for the first month, then \(renewalPrice)/year"
                : "per year",
            badge: eligible ? "INTRO OFFER" : nil,
            ctaTitle: eligible ? "START FOR \(introductoryPrice)" : "CHOOSE YEARLY",
            package: package
        )
    }

    private var lifetimePlan: PaywallPlan {
        let package = validatedPackage(generalOffering?.lifetime, productID: Self.lifetimeProductID)
        return PaywallPlan(
            kind: .lifetime,
            title: "LIFETIME",
            price: package?.storeProduct.localizedPriceString ?? "$14.99",
            caption: "one-time · yours forever",
            badge: nil,
            ctaTitle: "UNLOCK FOREVER",
            package: package
        )
    }

    // MARK: Private

    private func refreshCustomerInfo() async {
        guard storeIsLive, let info = try? await Purchases.shared.customerInfo() else { return }
        apply(info)
    }

    private func generalOffering(from offerings: Offerings) -> Offering? {
        offerings.current ?? offerings.all[Self.defaultOfferingID]
    }

    private func validatedPackage(_ package: Package?, productID: String) -> Package? {
        guard package?.storeProduct.productIdentifier == productID else { return nil }
        return package
    }

    private func isEligibleForIntroOffer(_ package: Package?) -> Bool {
        guard let product = package?.storeProduct,
              product.introductoryDiscount != nil
        else { return false }
        return introEligibility[product.productIdentifier]?.isEligible == true
    }

    private func apply(_ info: CustomerInfo) {
        isPremium = info.entitlements.active[Self.entitlementID] != nil
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
            "You already own this - try Restore Purchases."
        default:
            "The purchase didn't go through and you haven't been charged. Please try again."
        }
    }
}
