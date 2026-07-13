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
    /// to pick up.
    func pullNow(repo: Repository) {
        guard let urlString = CloudSyncSettings.serverURL, let token = CloudSyncSettings.token,
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
                    // Only re-export what could plausibly have changed on Health's side. A fresh bridge
                    // starts at auth == .unknown (it isn't the app's long-lived HealthKitBridge instance),
                    // so prime it from the existing grant — refreshAuthIfPreviouslyGranted only READS
                    // share status, it never prompts — before attempting the write-back.
                    if summary.touchedSleep || summary.touchedWorkouts || summary.touchedHr {
                        do {
                            let bridge = HealthKitBridge(repo: repo, appleDeviceId: "apple-health", noopDeviceId: "my-whoop")
                            bridge.refreshAuthIfPreviouslyGranted()
                            try await bridge.rerunWriteBack(whoopStore: store, days: 30)
                        } catch {
                            line += " · Apple Health re-export failed: \(error.localizedDescription)"
                        }
                    }
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
