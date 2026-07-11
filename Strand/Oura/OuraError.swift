import Foundation

/// User-facing failure reasons for the Oura cloud-import lane, mapped to clear, non-crashing messages.
/// Mirrors AICoachError's shape (LocalizedError + errorDescription).
enum OuraError: LocalizedError, Equatable {
    case notConnected
    case authFailed(String)
    case tokenExchangeFailed(String)
    case badResponse(Int, String)
    case rateLimited
    case network(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect your Oura account first."
        case .authFailed(let d):
            return "Oura sign-in didn't complete: \(d)"
        case .tokenExchangeFailed(let d):
            return "Couldn't exchange the Oura authorization code: \(d)"
        case .badResponse(let code, let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return "Oura returned an error (\(code))\(extra)."
        case .rateLimited:
            return "Oura is rate-limiting requests. Waiting before retrying."
        case .network(let d):
            return "Network problem talking to Oura: \(d)"
        case .decode:
            return "Couldn't read Oura's response."
        }
    }
}
