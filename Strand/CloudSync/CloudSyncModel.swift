// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation
import WhoopStore
#if os(iOS)
import UIKit
#endif

/// Drives the Data Sources "Cloud Sync" card: save the noop-cloud server URL + token → pull confirmed
/// edits → apply them locally → (iOS) re-export whatever changed into Apple Health. @MainActor so every
/// `@Published` mutation is main-thread; the network/apply/write-back work hops off-main.
///
/// `repo: Repository` is taken as a call-time PARAMETER (not stored at construction), for the same
/// reason as `OuraConnectModel`: `Repository` only reaches `DataSourcesView` via `@EnvironmentObject`,
/// which SwiftUI populates after `init()` runs.
@MainActor
final class CloudSyncModel: ObservableObject {
    @Published var busy = false
    @Published var statusText: String?
    /// True once both a server URL and a token are stored in the Keychain (`CloudSyncSettings`).
    @Published var isConfigured = CloudSyncSettings.isConfigured

    /// Validates `url` parses as an absolute URL (scheme + host) via `URLComponents` before saving.
    /// `CloudSyncClient.url(path:query:)` force-unwraps its `URLComponents`-built request URL, so a
    /// garbage base URL saved here would crash later at the first pull instead of failing this save
    /// with a clear, recoverable message (flagged in the Task-3 review of `CloudSyncClient`).
    func saveSettings(url: String, token: String) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedToken.isEmpty else {
            statusText = "Enter both a server URL and a token."
            return
        }
        guard let comps = URLComponents(string: trimmedURL), let scheme = comps.scheme, !scheme.isEmpty,
              let host = comps.host, !host.isEmpty else {
            statusText = "That doesn't look like a valid server URL (needs e.g. https://host)."
            return
        }
        CloudSyncSettings.serverURL = trimmedURL
        CloudSyncSettings.token = trimmedToken
        isConfigured = CloudSyncSettings.isConfigured
        statusText = "Saved."
    }

    /// Pull confirmed edits since this device's cursor, apply them, and — on iOS — re-export whatever
    /// changed into Apple Health. `repo.refresh()` runs unconditionally at the end (not just on
    /// success): `CloudEditApplier` writes land in the local store BEFORE `ack`, so even a pull that
    /// ultimately throws (e.g. the ack call itself failing) can leave real local changes the UI needs
    /// to pick up. Uses the EFFECTIVE credentials (`CloudSyncSettings.effectiveURL`/`effectiveToken`)
    /// so a bundle-only configuration (Phase 3.5, no Keychain save) works here too, not just in
    /// `syncNow`.
    func pullNow(repo: Repository) {
        guard let urlString = CloudSyncSettings.effectiveURL, let token = CloudSyncSettings.effectiveToken,
              let url = URL(string: urlString) else {
            statusText = "Add your noop-cloud server URL and token first."
            return
        }
        setBusy(true); statusText = "Pulling edits…"
        Task {
            var line: String
            if let store = await repo.storeHandle() {
                let client = CloudSyncClient(baseURL: url, token: token)
                do {
                    let summary = try await CloudSyncCoordinator.pull(store: store, client: client)
                    line = "Applied \(summary.applied) · skipped \(summary.skipped) · \(summary.needsAttention) need attention"
                    #if os(iOS) && canImport(HealthKit)
                    line += await reExportToAppleHealthIfNeeded(repo: repo, store: store, summary: summary)
                    #endif
                } catch {
                    line = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            } else {
                line = "No local store."
            }
            statusText = line
            await repo.refresh()
            setBusy(false)
        }
    }

    /// Upload this device's own `.noopbak` to the noop-cloud server, then pull + apply any confirmed
    /// edits — the two halves of "zero-touch" in one round trip: this device's own data reaches the
    /// server, and any edits confirmed elsewhere reach this device. Stamps
    /// `UserDefaults["cloudsync.lastAutoSync"]` on SUCCESS ONLY, so a failed attempt (server
    /// unreachable, network down) never blocks the next 20h-gated retry. Used by both the
    /// user-initiated "Sync now" button and `autoSyncIfDue`'s on-launch catch-up — a manual tap also
    /// resets the on-launch catch-up clock, so it doesn't immediately re-fire on the next launch.
    func syncNow(repo: Repository) {
        guard let urlString = CloudSyncSettings.effectiveURL, let token = CloudSyncSettings.effectiveToken,
              let url = URL(string: urlString) else {
            statusText = "Add your noop-cloud server URL and token first."
            return
        }
        setBusy(true); statusText = "Uploading…"
        Task {
            var line: String
            var succeeded = false
            if let store = await repo.storeHandle() {
                let client = CloudSyncClient(baseURL: url, token: token)
                do {
                    let uploaded = try await CloudSyncUploader.upload(store: store, client: client)
                    let mb = Double(uploaded.bytes) / 1_048_576.0
                    statusText = String(format: "Uploaded %.1f MB · pulling edits…", mb)

                    let summary = try await CloudSyncCoordinator.pull(store: store, client: client)
                    var parts = [String(format: "Uploaded %.1f MB", mb),
                                 "Applied \(summary.applied)", "skipped \(summary.skipped)"]
                    if summary.needsAttention > 0 { parts.append("\(summary.needsAttention) attention") }
                    line = parts.joined(separator: " · ")
                    succeeded = true
                    #if os(iOS) && canImport(HealthKit)
                    line += await reExportToAppleHealthIfNeeded(repo: repo, store: store, summary: summary)
                    #endif
                } catch {
                    line = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            } else {
                line = "No local store."
            }
            statusText = line
            if succeeded {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastAutoSyncKey)
            }
            await repo.refresh()
            setBusy(false)
        }
    }

    /// UserDefaults key for the last successful `syncNow` (manual or automatic) — read by
    /// `autoSyncIfDue`, written by `syncNow` on success only.
    private static let lastAutoSyncKey = "cloudsync.lastAutoSync"

    /// Pure 20h gate, `(lastRun, now) -> Bool`, so the threshold is unit-testable without UserDefaults,
    /// a store, or a network (see `CloudSyncModelAutoSyncGateTests`). `lastRun == 0` (never synced) is
    /// always due — a fresh install syncs on its very first launch, matching "zero manual taps".
    /// `nonisolated`: touches no actor-isolated state, so it's callable synchronously from a plain
    /// (non-`@MainActor`, non-`async`) XCTest method — without this, it inherits the enclosing class's
    /// `@MainActor` and a test would need `await MainActor.run { … }` just to call a pure function.
    nonisolated static func isAutoSyncDue(lastRun: TimeInterval, now: TimeInterval,
                                           intervalS: TimeInterval = 20 * 3600) -> Bool {
        now - lastRun >= intervalS
    }

    /// On-launch daily catch-up (Phase 3.5: zero-touch): silently no-ops when the lane isn't configured
    /// — `CloudSyncSettings.isConfigured` already covers both a bundle-injected build and a manual
    /// Keychain save — otherwise fires `syncNow` when it's been >20h since the last success. Call-time
    /// `repo:` parameter, same reason as every other method here (see the `@StateObject` declaration's
    /// note). A plain (non-`async`) MainActor call, mirroring `pullNow`/`syncNow`'s own shape: it
    /// spawns its OWN `Task` internally and returns immediately, so a caller on the launch-critical path
    /// (`RootView`/`RootTabView`'s `.task`) is never blocked waiting on the network.
    func autoSyncIfDue(repo: Repository) {
        guard CloudSyncSettings.isConfigured else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastAutoSyncKey)
        guard Self.isAutoSyncDue(lastRun: last, now: Date().timeIntervalSince1970) else { return }
        syncNow(repo: repo)
    }

    #if os(iOS) && canImport(HealthKit)
    /// Re-export into Apple Health when a pulled batch touched sleep/workouts/HR — shared by `pullNow`
    /// and `syncNow` so both surface the same "Apple Health re-export failed" note. Only re-exports
    /// what could plausibly have changed on Health's side. A fresh bridge starts at auth == .unknown
    /// (it isn't the app's long-lived HealthKitBridge instance), so prime it from the existing grant —
    /// `refreshAuthIfPreviouslyGranted` only READS share status, it never prompts — before attempting
    /// the write-back. Returns a status-line SUFFIX: empty when nothing ran or it succeeded.
    private func reExportToAppleHealthIfNeeded(repo: Repository, store: WhoopStore,
                                                summary: CloudApplySummary) async -> String {
        guard summary.touchedSleep || summary.touchedWorkouts || summary.touchedHr else { return "" }
        do {
            let bridge = HealthKitBridge(repo: repo, appleDeviceId: "apple-health", noopDeviceId: "my-whoop")
            bridge.refreshAuthIfPreviouslyGranted()
            try await bridge.rerunWriteBack(whoopStore: store, days: 30)
            return ""
        } catch {
            return " · Apple Health re-export failed: \(error.localizedDescription)"
        }
    }
    #endif

    /// Busy also pins the screen awake on iOS, mirroring `OuraConnectModel.setBusy`: the pull +
    /// Apple Health re-export is a foreground async flow, and an auto-lock mid-run suspends the app
    /// and freezes it with no error. Always reset on exit.
    private func setBusy(_ b: Bool) {
        busy = b
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = b
        #endif
    }
}
#endif // CLOUD_SYNC
