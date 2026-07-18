# Poser RevenueCat Configuration

I have completed the initial RevenueCat setup for my iOS app **Poser: Pose Camera**.

## App details

* App name: `Poser: Pose Camera`
* Platform: iOS
* Apple bundle identifier: `space.concurrent.poser`
* RevenueCat project: `Poser`
* RevenueCat app/store: Apple App Store
* App Store Connect is already connected to RevenueCat.
* The app must use Poser’s RevenueCat **public iOS SDK key**, not the StyleSnap API key.

## Premium entitlement

I created one RevenueCat entitlement:

```text
premium
```

All paid products unlock the same `premium` entitlement.

The app should check access using the `premium` entitlement rather than checking individual product IDs.

Example logic:

```ts
const hasPremium =
  customerInfo.entitlements.active["premium"] !== undefined;
```

## Apple and RevenueCat products

I have four products:

### Monthly subscription

```text
Product ID: space.concurrent.poser.monthly
Type: Auto-renewable subscription
Duration: 1 month
Price: $1.99 per month
```

### Standard yearly subscription

```text
Product ID: space.concurrent.poser.yearly
Type: Auto-renewable subscription
Duration: 1 year
Standard price: $9.99 per year
Introductory offer: 7-day free trial
```

After the trial, the user is charged the normal yearly price and the subscription automatically renews yearly.

### Onboarding yearly subscription

```text
Product ID: space.concurrent.poser.yearly_intro30
Type: Auto-renewable subscription
Duration: 1 year
Standard price: $9.99 per year
Introductory offer: $0.99 for the first month
```

After the discounted first month, the user is charged the normal yearly price and the subscription automatically renews yearly.

This should be described as:

```text
$0.99 for the first month, then $9.99/year
```

It must not be described as a free month.

### Lifetime purchase

```text
Product ID: space.concurrent.poser.lifetime
Type: Non-consumable in-app purchase
Price: $14.99 once
```

The lifetime purchase permanently unlocks the `premium` entitlement.

## Apple subscription group

The following products are in the same Apple subscription group:

```text
space.concurrent.poser.monthly
space.concurrent.poser.yearly
space.concurrent.poser.yearly_intro30
```

The lifetime non-consumable is separate from the subscription group.

Because both yearly products are in the same subscription group, a user can only redeem one introductory offer from that group.

For example:

* Using the 7-day free trial makes the user ineligible for the $0.99 introductory month.
* Using the $0.99 introductory month makes the user ineligible for the 7-day free trial.
* Merely seeing or dismissing the onboarding paywall does not consume either offer.
* Apple makes the final decision about introductory-offer eligibility.

## RevenueCat offering 1: Onboarding

I created this offering:

```text
Identifier: onboarding
Display Name: Onboarding Offers
```

It contains only two yearly choices:

```text
Custom package: annual_7_day_trial
Product: space.concurrent.poser.yearly
Offer: 7 days free, then $9.99/year
```

```text
Custom package: annual_intro_30_day
Product: space.concurrent.poser.yearly_intro30
Offer: $0.99 for the first month, then $9.99/year
```

These use custom package identifiers because both products are annual subscriptions and cannot both use the same `$rc_annual` package identifier inside one offering.

The onboarding flow should explicitly retrieve the offering with the identifier:

```text
onboarding
```

It should not rely on `offerings.current` for this screen.

Example:

```ts
const offerings = await Purchases.getOfferings();
const onboardingOffering = offerings.all["onboarding"];
```

## RevenueCat offering 2: General paywall

I created this offering:

```text
Identifier: default
Display Name: Standard App Paywall
```

This is the normal paywall shown inside the app after onboarding.

It contains:

```text
Package: $rc_monthly
Product: space.concurrent.poser.monthly
Price: $1.99/month
```

```text
Package: $rc_annual
Product: space.concurrent.poser.yearly
Offer for eligible users: 7 days free, then $9.99/year
```

```text
Package: $rc_lifetime
Product: space.concurrent.poser.lifetime
Price: $14.99 once
```

The `default` offering should be set as RevenueCat’s current/default offering.

The general paywall can retrieve it using:

```ts
const offerings = await Purchases.getOfferings();
const generalOffering =
  offerings.current ?? offerings.all["default"];
```

## Paywall behaviour

### Onboarding paywall

Show only:

1. Seven-day free trial yearly plan
2. $0.99 first-month yearly plan

Do not show monthly or lifetime during onboarding.

### General app paywall

Show:

1. Monthly
2. Standard yearly
3. Lifetime

The standard yearly option should still advertise the seven-day trial when the customer is eligible and did not already redeem another introductory offer.

For ineligible users, the yearly option should display the normal yearly price without promising a free trial.

Do not hardcode trial eligibility based only on whether the user previously viewed the onboarding screen. Eligibility is connected to the customer’s Apple subscription-group history.

## Purchase handling

All purchases should use the RevenueCat package selected from the relevant offering.

After a successful purchase, check:

```ts
customerInfo.entitlements.active["premium"]
```

Do not unlock premium based solely on the product identifier or on the purchase function returning without an error.

Premium access must work for:

* Active monthly subscriptions
* Active yearly subscriptions
* Users currently inside a trial or introductory period
* Lifetime purchasers
* Restored purchases

The app must also include a **Restore Purchases** button.

Example:

```ts
const customerInfo = await Purchases.restorePurchases();

const hasPremium =
  customerInfo.entitlements.active["premium"] !== undefined;
```

## Expected final RevenueCat structure

```text
Poser RevenueCat project
│
├── Apple app
│   └── Bundle ID: space.concurrent.poser
│
├── Entitlement
│   └── premium
│       ├── space.concurrent.poser.monthly
│       ├── space.concurrent.poser.yearly
│       ├── space.concurrent.poser.yearly_intro30
│       └── space.concurrent.poser.lifetime
│
├── Offering: onboarding
│   ├── annual_7_day_trial
│   │   └── space.concurrent.poser.yearly
│   └── annual_intro_30_day
│       └── space.concurrent.poser.yearly_intro30
│
└── Offering: default
    ├── $rc_monthly
    │   └── space.concurrent.poser.monthly
    ├── $rc_annual
    │   └── space.concurrent.poser.yearly
    └── $rc_lifetime
        └── space.concurrent.poser.lifetime
```

Implement the app around these existing RevenueCat identifiers. Do not create replacement product IDs, entitlements, packages, or offerings unless there is a confirmed configuration error.
