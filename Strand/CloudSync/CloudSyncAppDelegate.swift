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
        // Breadcrumb (readable via the app container's preferences plist): which leg of
        // token→POST last ran, so a silent registration failure is diagnosable without a debugger.
        UserDefaults.standard.set("token-received \(Date())", forKey: Self.registrationBreadcrumbKey)
        let client = CloudSyncClient(baseURL: url, token: token)
        Task {
            do {
                try await client.registerDevice(token: hexToken)
                UserDefaults.standard.set("registered \(Date())", forKey: Self.registrationBreadcrumbKey)
            } catch CloudSyncError.badResponse(404, _) {
                // Expected during rollout: the server's /register-device endpoint ships in parallel
                // with this client. Benign — a fresh install, a token refresh (APNs rotates tokens
                // occasionally), or simply the next relaunch after the server catches up will retry
                // this same call, so there's nothing to recover here.
                UserDefaults.standard.set("post-404 \(Date())", forKey: Self.registrationBreadcrumbKey)
            } catch {
                // Any other failure (network down, non-404 error): log-not-crash, matching every other
                // CloudSync network call's posture — push registration is a nice-to-have, never
                // something worth surfacing to the user or aborting launch over.
                UserDefaults.standard.set("post-error: \(error) \(Date())", forKey: Self.registrationBreadcrumbKey)
            }
        }
    }

    /// UserDefaults key for the registration breadcrumb above — diagnosis-only, never read by code.
    static let registrationBreadcrumbKey = "cloudsync.push.lastRegistration"

    /// Request APNs registration HERE — the canonical didFinishLaunching site — not from
    /// `StrandiOSApp.init()`: a request made during the SwiftUI `App` struct's init runs BEFORE the
    /// app finishes launching, and UIKit silently ignores it (found live: no token callback and no
    /// failure callback ever fired; the breadcrumb below never advanced past absent).
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if CloudSyncSettings.effectiveURL != nil, CloudSyncSettings.effectiveToken != nil {
            UserDefaults.standard.set("requested \(Date())", forKey: Self.registrationBreadcrumbKey)
            application.registerForRemoteNotifications()
        }
        return true
    }

    /// Expected on EVERY launch of this branch (see the type's doc comment: no `aps-environment`
    /// entitlement yet). Silent — there is no user-facing push-status UI to update, and the
    /// BGAppRefreshTask + on-launch catch-up paths cover the same ground without APNs at all.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set("os-fail: \(error.localizedDescription) \(Date())",
                                  forKey: Self.registrationBreadcrumbKey)
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
        // Breadcrumb, same diagnosis-only idiom as `registrationBreadcrumbKey`. Registration and
        // DELIVERY fail independently: a phone can hold a valid token and register cleanly while iOS
        // still never hands the push over (a force-quit app is never woken for content-available,
        // Low Power Mode, Background App Refresh off). The server side cannot tell the two apart
        // either — APNs answers 200 for a token it has not yet marked Unregistered, so
        // `request_sync` reports a delivered push in both cases. Without a receipt written HERE the
        // only observable is "the sync didn't happen", which is equally consistent with the push
        // never arriving and with the sync bailing after it did (exactly the ambiguity of
        // 2026-08-24's stale-mirror incident).
        //
        // The breadcrumb also records `backgroundTimeRemaining` at both ends of the
        // `beginBackgroundTask` call below, because the size of this window is the whole question for
        // this lane and it is not a documented constant: a push-woken app gets a short budget, and a
        // full sync here has to fit a WAL checkpoint plus a ~150MB `.noopbak` export
        // (`CloudSyncUploader.upload`) plus the upload itself inside it. Measured, not assumed.
        let budgetBefore = application.backgroundTimeRemaining
        UserDefaults.standard.set("received (budget \(Self.fmtBudget(budgetBefore))) \(Date())",
                                  forKey: Self.receiptBreadcrumbKey)
        guard let model = Self.model else {
            UserDefaults.standard.set("received-but-no-model \(Date())", forKey: Self.receiptBreadcrumbKey)
            completionHandler(.noData)
            return
        }
        // Hold an expiration-handled background assertion for the whole sync: it is what keeps the
        // export + upload alive past the bare push-wake budget, and it means a suspension mid-sync
        // is an EXPLICIT expiration (recorded below) rather than a silent freeze that abandons the
        // `CloudSyncGate` hold until `CloudSyncGate.staleHoldS` reclaims it half an hour later.
        // Ended on BOTH exits: normal completion in the Task below, and expiration here.
        endPushBackgroundTask() // a REDELIVERED push must not leak the previous assertion
        pushBackgroundTask = application.beginBackgroundTask(withName: "cloudsync.push") { [weak self] in
            // Fires when iOS is about to reclaim the assertion. Record it — "expired" vs a missing
            // `sync ran=` is exactly the distinction that says whether the window is the binding
            // constraint — then release, or iOS kills the app outright for holding past expiry.
            // UserDefaults is thread-safe; the release hops to the main actor that owns the identifier.
            UserDefaults.standard.set("EXPIRED mid-sync \(Date())", forKey: CloudSyncAppDelegate.receiptBreadcrumbKey)
            Task { @MainActor in self?.endPushBackgroundTask() }
        }
        UserDefaults.standard.set(
            "received (budget \(Self.fmtBudget(budgetBefore)) -> \(Self.fmtBudget(application.backgroundTimeRemaining))) \(Date())",
            forKey: Self.receiptBreadcrumbKey)
        let cloudSync = CloudSyncModel()
        let intelligence = model.intelligence
        let repository = model.repo
        cloudSync.postApplyRefresh = {
            await intelligence.analyzeRecent()
            await repository.refresh()
        }
        Task {
            // Unconditional (CloudSyncGate-guarded) — see `syncFromPush`'s doc comment: the 4h
            // staleness gate belongs to the OS-initiated BGAppRefresh path, not to an explicit
            // server-side request for fresh data.
            let ran = await cloudSync.syncFromPush(repo: repository)
            UserDefaults.standard.set("sync ran=\(ran) \(Date())", forKey: Self.receiptBreadcrumbKey)
            completionHandler(ran ? .newData : .noData)
            self.endPushBackgroundTask()
        }
    }

    /// UserDefaults key for the push-DELIVERY breadcrumb above — the receive-side counterpart to
    /// `registrationBreadcrumbKey`. Diagnosis-only; surfaced read-only by the Test Centre's
    /// replication card so a silent push failure is attributable without a debugger.
    static let receiptBreadcrumbKey = "cloudsync.push.lastReceipt"

    /// The assertion taken in `didReceiveRemoteNotification`, held for the life of that sync.
    /// `.invalid` whenever none is outstanding, which is what makes `endPushBackgroundTask`
    /// idempotent — it is deliberately called on several paths that can race.
    private var pushBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Idempotent release. Ending an already-ended (or never-taken) identifier is an API misuse that
    /// throws, hence the guard rather than an unconditional `endBackgroundTask`.
    private func endPushBackgroundTask() {
        guard pushBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(pushBackgroundTask)
        pushBackgroundTask = .invalid
    }

    /// `backgroundTimeRemaining` is `.greatestFiniteMagnitude` while the app is foregrounded (no
    /// budget applies), which would otherwise render as a meaningless 1.7976931348623157e+308 in the
    /// breadcrumb and hide the one case that matters — a real, finite, small background window.
    private static func fmtBudget(_ seconds: TimeInterval) -> String {
        seconds > 86_400 ? "foreground" : String(format: "%.0fs", seconds)
    }
}
#endif // os(iOS)
#endif // CLOUD_SYNC
