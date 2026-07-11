import Foundation
import AuthenticationServices

/// The auth seam. Today's concrete provider is `OuraOAuthProvider` (BYO-app authorization-code, Task 3);
/// a future backend-mediated provider can replace it without touching the API client or the sync layer.
protocol AuthProvider {
    /// True when tokens are stored (connected), regardless of expiry.
    var isConnected: Bool { get }
    /// Return a currently-valid access token, refreshing transparently if the stored one is expired.
    func validAccessToken() async throws -> String
    /// Force an unconditional refresh (regardless of expiry) and return the new access token.
    /// Used when a token was rejected server-side (401) even though it wasn't clock-expired.
    func refreshedAccessToken() async throws -> String
    /// Run the interactive authorization (opens Oura's consent page) and store the resulting tokens.
    @MainActor func authorize(presentationAnchor: ASPresentationAnchor) async throws
    /// Forget the stored tokens (disconnect).
    func signOut()
}
