import CryptoKit
import Foundation
import SafariServices
import SwiftUI

enum PKCE {
    static func make() -> (verifier: String, challenge: String, state: String) {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        let verifier = Data(bytes).base64URLEncoded()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        return (verifier, challenge, UUID().uuidString)
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum DevinAuth {
    /// Same PKCE handshake `devin auth login --force-manual-token-flow` uses:
    /// the user signs in on app.devin.ai, the page shows a code, and the code
    /// is exchanged for a non-expiring user token at api.devin.ai/auth/cli/token.
    static func signInURL(state: String, codeChallenge: String) -> URL {
        var components = URLComponents(
            string: "https://app.devin.ai/auth/cli/continue"
        )!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "cli_pkce_marker", value: "1"),
        ]
        return components.url!
    }

    static func exchange(code: String, verifier: String) async throws -> String {
        var urlRequest = URLRequest(url: URL(string: "https://api.devin.ai/auth/cli/token")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
        ])

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, body: "unexpected response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: String(text.prefix(300)))
        }
        guard let token = extractToken(from: data) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: "no token field in: \(text.prefix(300))")
        }
        return token
    }

    /// The exchange response shape isn't documented — pull the first plausible
    /// token string out of whatever JSON the server returns.
    private static func extractToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var candidates: [String] = []
        collectStrings(object, into: &candidates)
        return candidates.first { $0.hasPrefix("cog_") }
            ?? candidates.first { $0.count >= 20 }
    }

    private static func collectStrings(_ value: Any, into out: inout [String]) {
        switch value {
        case let string as String:
            out.append(string)
        case let dict as [String: Any]:
            for key in ["token", "api_key", "access_token", "session_token", "devin_token"] {
                if let hit = dict[key] { collectStrings(hit, into: &out) }
            }
            for (key, val) in dict where !["token", "api_key", "access_token", "session_token", "devin_token"].contains(key) {
                collectStrings(val, into: &out)
            }
        case let array as [Any]:
            for item in array { collectStrings(item, into: &out) }
        default:
            break
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
