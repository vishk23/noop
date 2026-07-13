// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
#if os(iOS)
import Foundation
import UIKit

/// Minimal `UIApplicationDelegate` shim (Cloud Sync v2) — `StrandiOSApp` is otherwise a pure SwiftUI
/// `App` with no AppDelegate at all (confirmed: no `@UIApplicationDelegateAdaptor` existed before this).
/// APNs device-token registration and silent (content-available) push delivery are UIKit AppDelegate
/// callbacks with no SwiftUI equivalent — `.onReceive`/`.task` can't observe them — so this is the
/// ONLY reason an AppDelegate exists in this app. CLOUD_SYNC + iOS gated: a default build never links
/// any of this push-notification plumbing at all.
///
/// CODE-COMPLETE, CREDENTIALS LATER: `NOOP.entitlements` does NOT carry `aps-environment` in this
/// branch (deliberately — the integrator adds it when APNs credentials/signing are ready), so
/// `registerForRemoteNotifications()` will fail every launch until that lands.
/// `didFailToRegisterForRemoteNotificationsWithError` below is expected to fire on every run of this
/// build for exactly that reason.
@MainActor
final class CloudSyncAppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `StrandiOSApp.init()` (alongside the `registerForRemoteNotifications()` call) before any
    /// delegate callback below can plausibly fire, so `didReceiveRemoteNotification` can run the same
    /// gated background sync `CloudSyncBackgroundRefresh` uses — this class has no other way to reach
    /// the shared `AppModel`/`Repository`/`IntelligenceEngine` (a `UIApplicationDelegateAdaptor`
    /// instance is constructed by SwiftUI, not by `StrandiOSApp.init()`, so it can't be handed the
    /// model at init time the way `CloudSyncBackgroundRefresh.register(model:)` is).
    static var model: AppModel?

    /// APNs handed us a device token: hex-encode it (APNs' own wire format) and hand it to the
    /// server's `/register-device` endpoint. Best-effort and silent either way — see
    /// `CloudSyncClient.registerDevice`'s doc comment for why the server 404 case specifically is
    /// EXPECTED (it ships in parallel with this client) rather than a real failure.
    func application(_ application: UIApplication,
                      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard let urlString = CloudSyncSettings.effectiveURL, let token = CloudSyncSettings.effectiveToken,
              let url = URL(string: urlString) else { return }
        let hexToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        let client = CloudSyncClient(baseURL: url, token: token)
        Task {
            do {
                try await client.registerDevice(token: hexToken)
            } catch CloudSyncError.badResponse(404, _) {
                // Expected during rollout: the server's /register-device endpoint ships in parallel
                // with this client. Benign — a fresh install, a token refresh (APNs rotates tokens
                // occasionally), or simply the next relaunch after the server catches up will retry
                // this same call, so there's nothing to recover here.
            } catch {
                // Any other failure (network down, non-404 error): log-not-crash, matching every other
                // CloudSync network call's posture — push registration is a nice-to-have, never
                // something worth surfacing to the user or aborting launch over.
            }
        }
    }

    /// Expected on EVERY launch of this branch (see the type's doc comment: no `aps-environment`
    /// entitlement yet). Silent — there is no user-facing push-status UI to update, and the
    /// BGAppRefreshTask + on-launch catch-up paths cover the same ground without APNs at all.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    }

    /// A silent (content-available) push arrived: run the SAME gated background sync the
    /// `BGAppRefreshTask` handler uses (`CloudSyncBackgroundRefresh.handle`), then report the fetch
    /// result iOS expects. A push is a stronger signal than the 4h background-refresh gate ("a
    /// specific edit is now confirmed and waiting"), but it still goes through
    /// `backgroundSyncIfDue`'s SAME `CloudSyncGate`/staleness gate rather than an unconditional sync —
    /// a burst of pushes (or a redelivered one) must not be able to fire overlapping syncs any more
    /// than two backgrounded refreshes could. `.newData`/`.noData` is a coarse signal (this handler has
    /// no per-byte insight into what changed): `.newData` whenever a sync was actually ATTEMPTED,
    /// `.noData` when a guard sent it home early (e.g. the 4h gate hasn't elapsed, or CloudSync isn't
    /// configured on this device).
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                      fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let model = Self.model else {
            completionHandler(.noData)
            return
        }
        let cloudSync = CloudSyncModel()
        let intelligence = model.intelligence
        let repository = model.repo
        cloudSync.postApplyRefresh = {
            await intelligence.analyzeRecent()
            await repository.refresh()
        }
        Task {
            let ran = await cloudSync.backgroundSyncIfDue(repo: repository)
            completionHandler(ran ? .newData : .noData)
        }
    }
}
#endif // os(iOS)
#endif // CLOUD_SYNC
