import Aptabase
import Foundation
import Sentry

/// Wraps Sentry (always-on crash/error reporting) and Aptabase (opt-out
/// product analytics) behind one call surface, so feature code never touches
/// either SDK directly and stays correct whether or not either is configured.
///
/// Analytics events must stay low-cardinality and content-free: feature
/// names, booleans, counts, and fixed option values are fine - item names,
/// photo/pose file paths, exact timestamps, and any other user-authored
/// content must never be sent. Error reports follow the same rule: Sentry is
/// configured with `sendDefaultPii = false` and no session replay, so no
/// screen content or personal data is captured alongside a stack trace.
enum Analytics {
    static let optOutKey = "analyticsOptOut"
    private static var aptabaseConfigured = false

    /// Product analytics (Aptabase) default to on; the user can opt out in
    /// Settings. Crash/error reporting (Sentry) has no toggle - it always
    /// runs once configured, matching the Privacy Policy.
    static var isOptedOut: Bool {
        get { UserDefaults.standard.bool(forKey: optOutKey) }
        set { UserDefaults.standard.set(newValue, forKey: optOutKey) }
    }

    static func configure() {
        configureSentry()
        configureAptabase()
    }

    /// Sends a low-cardinality, content-free product event. A silent no-op if
    /// Aptabase isn't configured (no app key yet) or the user opted out.
    static func track(_ event: String, _ properties: [String: Value] = [:]) {
        guard aptabaseConfigured, !isOptedOut else { return }
        Aptabase.shared.trackEvent(event, with: properties)
    }

    /// Reports a caught error to Sentry, tagged by the feature area it came
    /// from, so an operational failure (a save, an export, a capture) is
    /// visible without interrupting the friendly in-app alert already shown
    /// at the call site. A silent no-op if Sentry isn't configured.
    static func captureError(_ error: Error, area: String) {
        guard isSentryConfigured else { return }
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: area, key: "area")
        }
    }

    private static var isSentryConfigured = false

    private static func configureSentry() {
        guard Secrets.sentryDSN.hasPrefix("https://"), !Secrets.sentryDSN.contains("REPLACE") else { return }
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
#if DEBUG
            options.environment = "development"
#else
            options.environment = "production"
#endif
            // A camera app does real image work on the main thread; keep
            // reporting genuine hangs while avoiding a feed full of brief
            // stalls during that work.
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 5
            options.enableWatchdogTerminationTracking = true

            // No IP/device contact info, and no session replay - Poser's
            // screens show the user's own photos, which must never leave
            // the device as part of a crash report.
            options.sendDefaultPii = false

            options.beforeSend = { event in
                // Apple Vision legitimately finds no subject in some photos.
                // The app keeps the original image and surfaces a friendly
                // in-app message, so this is an expected outcome, not an
                // operational error worth a Sentry issue.
                let isExpectedNoSubject = event.exceptions?.contains { exception in
                    exception.value?.contains("foreground subject") == true
                } ?? false
                return isExpectedNoSubject ? nil : event
            }
        }
        isSentryConfigured = true
    }

    private static func configureAptabase() {
        guard Secrets.aptabaseAppKey.hasPrefix("A-"), !Secrets.aptabaseAppKey.contains("REPLACE") else { return }
        Aptabase.shared.initialize(appKey: Secrets.aptabaseAppKey)
        aptabaseConfigured = true
    }
}
