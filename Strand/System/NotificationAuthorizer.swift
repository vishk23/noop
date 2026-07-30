import Foundation
import UserNotifications

/// Shared OS-notification authorization for the app's opt-in alerting features. Extracted from
/// `BatteryNotifier` once a SECOND feature — the iOS "Wrist alerts" master (inactivity + smart-alarm
/// mirror buzzes) — needed the identical check-then-ask-once-then-report flow. Keeping the
/// classification and the request in exactly one place means the features can't drift apart on what
/// counts as "authorized" (the bug this whole line of work fixes: a notifying toggle that never asks).
/// On-device only; no per-feature state — the caller owns the setting it gates.
enum NotificationAuthorizer {
    /// What the caller should do given the CURRENT authorization status, without touching the OS.
    /// Pure classification, kept as its own function so this decision has a seam a test can drive
    /// directly — inlining the equivalent switch inside a `getNotificationSettings` closure (as every
    /// notifier used to) needs a live `UNUserNotificationCenter` round-trip to exercise at all.
    enum AuthDecision { case proceed, mustAsk, deny }
    static func decision(for status: UNAuthorizationStatus) -> AuthDecision {
        switch status {
        case .authorized, .provisional, .ephemeral: return .proceed
        case .notDetermined: return .mustAsk
        default: return .deny   // .denied, or any future non-authorized case
        }
    }

    /// Outcome of an authorization check — lets the caller react instead of silently leaving a
    /// notifying feature "on" when the OS will never actually deliver. Mirrors `WindDownNudge.EnableOutcome`.
    enum EnableOutcome { case authorized, denied }

    /// Check current authorization and ask ONCE if undetermined, then report back on the main actor.
    /// Called when the user flips a notifying feature on (and, for a default-ON feature, once when its
    /// settings card first appears). Ask only when undetermined, never re-prompt once answered either
    /// way — the OS shows the system dialog exactly once, so a re-ask is a no-op that would mask the
    /// real state from the caller. Shape mirrors `WindDownNudge.setEnabled`.
    static func ensureAuthorized(completion: @escaping @MainActor (EnableOutcome) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch decision(for: settings.authorizationStatus) {
            case .proceed:
                Task { @MainActor in completion(.authorized) }
            case .mustAsk:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in completion(granted ? .authorized : .denied) }
                }
            case .deny:
                Task { @MainActor in completion(.denied) }
            }
        }
    }
}
