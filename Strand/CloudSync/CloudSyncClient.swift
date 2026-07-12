// Compiled ONLY when the CLOUD_SYNC compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if CLOUD_SYNC
import Foundation

/// User-facing failure reasons for the cloud-sync lane, mapped to clear, non-crashing messages.
/// Mirrors OuraError's shape (LocalizedError + errorDescription).
enum CloudSyncError: LocalizedError, Equatable {
    case badResponse(Int, String)
    case network(String)
    case decode

    var errorDescription: String? {
        switch self {
        case .badResponse(let code, let detail):
            let extra = detail.isEmpty ? "" : " — \(detail)"
            return "The cloud sync server returned an error (\(code))\(extra)."
        case .network(let d):
            return "Network problem talking to the cloud sync server: \(d)"
        case .decode:
            return "Couldn't read the cloud sync server's response."
        }
    }
}

/// The noop-cloud edit-journal client. Injected `session` makes it URLProtocol-testable.
/// Networking lives here in the app target by design (mirrors Strand/Oura/OuraAPIClient.swift).
final class CloudSyncClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// GET /edits?since=<cursor>, Bearer-authed. Returns the page of rows plus the server's latest seq.
    func fetchEdits(since: Int) async throws -> (edits: [CloudEdit], latestSeq: Int) {
        var req = URLRequest(url: url(path: "edits", query: ["since": String(since)]))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await send(req)
        guard (200..<300).contains(status) else {
            throw CloudSyncError.badResponse(status, bodyPrefix(data))
        }
        guard let decoded = try? JSONDecoder().decode(CloudEditsResponse.self, from: data) else {
            throw CloudSyncError.decode
        }
        return (decoded.edits, decoded.latestSeq)
    }

    /// POST /edits/ack {"seqs":[...]}, Bearer-authed. Returns the count the server actually acked.
    func ack(seqs: [Int]) async throws -> Int {
        var req = URLRequest(url: url(path: "edits/ack"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AckRequest(seqs: seqs))
        let (data, status) = try await send(req)
        guard (200..<300).contains(status) else {
            throw CloudSyncError.badResponse(status, bodyPrefix(data))
        }
        guard let decoded = try? JSONDecoder().decode(AckResponse.self, from: data) else {
            throw CloudSyncError.decode
        }
        return decoded.acked
    }

    private func url(path: String, query: [String: String] = [:]) -> URL {
        var comps = URLComponents(string: "\(baseURL.absoluteString)/\(path)")!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comps.url!
    }

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw CloudSyncError.network(error.localizedDescription)
        }
    }

    /// Truncates the response body to a bounded prefix for error messages (never surface an
    /// unbounded server body through an error description).
    private func bodyPrefix(_ data: Data) -> String {
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.count > 200 ? String(s.prefix(200)) : s
    }
}

private struct AckRequest: Encodable {
    let seqs: [Int]
}

private struct AckResponse: Decodable {
    let acked: Int
}
#endif // CLOUD_SYNC
