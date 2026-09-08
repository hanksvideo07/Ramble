import Foundation

enum APIError: LocalizedError {
    case notAuthenticated
    case server(String)
    case offline
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to continue."
        case .server(let message): message
        case .offline: "You're offline. Your recordings are safe and will sync when you reconnect."
        case .decoding(let detail): "Unexpected response from the server. (\(detail))"
        }
    }
}

/// Talks to the Ramble backend. The only place in the app that knows about
/// HTTP, so views and stores deal in models rather than requests.
actor APIClient {
    static let shared = APIClient()

    /// Where the backend lives.
    ///
    /// Defaults to the deployed server so a physical device works with no
    /// setup. Set `RAMBLE_API_URL` in the scheme's environment to point a
    /// build at a local server instead.
    static let deployedURL = "https://ramble-api-production.up.railway.app"

    private let baseURL: URL = {
        if let override = ProcessInfo.processInfo.environment["RAMBLE_API_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: deployedURL)!
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.flexible.date(from: raw) { return date }
            if let date = ISO8601DateFormatter.plain.date(from: raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognized date \(raw)")
            )
        }
        return decoder
    }()

    private let encoder = JSONEncoder()

    // MARK: - Session token

    private var token: String? {
        get { Keychain.read("session_token") }
    }

    func setToken(_ token: String?) {
        if let token { Keychain.write(token, for: "session_token") }
        else { Keychain.delete("session_token") }
    }

    var isSignedIn: Bool { token != nil }

    // MARK: - Requests

    private func request(
        _ method: String,
        _ path: String,
        body: (any Encodable)? = nil,
        authenticated: Bool = true
    ) throws -> URLRequest {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }
        if authenticated {
            guard let token else { throw APIError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Builds an absolute URL from a path that may carry a query string.
    ///
    /// `URL.appending(path:)` percent-encodes its argument as a single path
    /// component, which turns "?" into "%3F" and silently 404s every request
    /// with a query. Splitting the two apart keeps the query a query.
    private func url(for path: String) throws -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var components = URLComponents(
            url: baseURL.appending(path: String(parts[0])),
            resolvingAgainstBaseURL: false
        )
        if parts.count > 1, !parts[1].isEmpty {
            components?.percentEncodedQuery = String(parts[1])
        }
        guard let url = components?.url else {
            throw APIError.server("Could not build a request URL for \(path).")
        }
        return url
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await perform(request)
        try check(response, data: data)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError
            where [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                   .timedOut, .dataNotAllowed].contains(error.code) {
            throw APIError.offline
        }
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.notAuthenticated }
            // Surface the server's own wording; it is written for users.
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? "Request failed (\(http.statusCode))."
            throw APIError.server(message)
        }
    }

    private struct ErrorBody: Decodable { let error: String }

    // MARK: - Health

    func health() async throws -> HealthReport {
        try await send(request("GET", "/v1/health", authenticated: false), as: HealthReport.self)
    }

    // MARK: - Auth

    struct AuthResponse: Decodable {
        let token: String
        let user: Account
    }

    func register(email: String, password: String) async throws -> Account {
        let body = ["email": email, "password": password, "device": UIDeviceName.current]
        let response = try await send(
            request("POST", "/v1/auth/register", body: body, authenticated: false),
            as: AuthResponse.self
        )
        setToken(response.token)
        return response.user
    }

    func login(email: String, password: String) async throws -> Account {
        let body = ["email": email, "password": password, "device": UIDeviceName.current]
        let response = try await send(
            request("POST", "/v1/auth/login", body: body, authenticated: false),
            as: AuthResponse.self
        )
        setToken(response.token)
        return response.user
    }

    func logout() async {
        if let request = try? request("POST", "/v1/auth/logout") {
            _ = try? await perform(request)
        }
        setToken(nil)
    }

    func me() async throws -> Account {
        try await send(request("GET", "/v1/me"), as: Account.self)
    }

    func updateProfile(_ profile: UserProfile?, onboarded: Bool? = nil) async throws -> Account {
        struct Body: Encodable {
            let profile: String?
            let onboarded: Bool?
        }
        return try await send(
            request("PATCH", "/v1/me", body: Body(profile: profile?.rawValue, onboarded: onboarded)),
            as: Account.self
        )
    }

    // MARK: - Rambles

    struct CreateResponse: Decodable {
        let id: String
    }

    func createRamble(
        clientId: String,
        recordedAt: Date,
        duration: Double,
        source: String
    ) async throws -> String {
        struct Body: Encodable {
            let client_id: String
            let recorded_at: String
            let duration_seconds: Double
            let source_device: String
        }
        let body = Body(
            client_id: clientId,
            recorded_at: ISO8601DateFormatter.plain.string(from: recordedAt),
            duration_seconds: duration,
            source_device: source
        )
        return try await send(request("POST", "/v1/rambles", body: body), as: CreateResponse.self).id
    }

    /// Uploads the recording as multipart form data.
    func uploadAudio(rambleId: String, fileURL: URL) async throws {
        guard let token else { throw APIError.notAuthenticated }
        let boundary = "ramble.\(UUID().uuidString)"
        var request = URLRequest(url: try url(for: "/v1/rambles/\(rambleId)/audio"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: audio/m4a\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n")

        let (data, response) = try await perform({
            var request = request
            request.httpBody = body
            return request
        }())
        try check(response, data: data)
    }

    struct TimelinePage: Decodable {
        let rambles: [RambleCard]
        let nextCursor: Date?

        enum CodingKeys: String, CodingKey {
            case rambles
            case nextCursor = "next_cursor"
        }
    }

    func timeline(before: Date? = nil) async throws -> TimelinePage {
        var path = "/v1/rambles?limit=30"
        if let before { path += "&before=\(ISO8601DateFormatter.plain.string(from: before))" }
        return try await send(request("GET", path), as: TimelinePage.self)
    }

    func ramble(id: String) async throws -> RambleDetail {
        try await send(request("GET", "/v1/rambles/\(id)"), as: RambleDetail.self)
    }

    func deleteRamble(id: String) async throws {
        let (data, response) = try await perform(request("DELETE", "/v1/rambles/\(id)"))
        try check(response, data: data)
    }

    func reprocess(id: String) async throws {
        let (data, response) = try await perform(request("POST", "/v1/rambles/\(id)/reprocess"))
        try check(response, data: data)
    }

    // MARK: - Corrections

    func updateItem(
        id: String,
        kind: ItemKind? = nil,
        title: String? = nil,
        status: String? = nil
    ) async throws -> ExtractedItem {
        struct Body: Encodable {
            let kind: String?
            let title: String?
            let status: String?
        }
        return try await send(
            request("PATCH", "/v1/items/\(id)",
                    body: Body(kind: kind?.rawValue, title: title, status: status)),
            as: ExtractedItem.self
        )
    }

    func mergeEntity(_ id: String, into target: String) async throws {
        struct Body: Encodable { let into_entity_id: String }
        let (data, response) = try await perform(
            request("POST", "/v1/entities/\(id)/merge", body: Body(into_entity_id: target))
        )
        try check(response, data: data)
    }

    /// Sends a transcript produced on the device, so the server does not pay a
    /// cloud service to redo work the phone already did.
    func uploadTranscript(
        rambleId: String,
        text: String,
        locale: String,
        segments: [OnDeviceTranscriptSegment]
    ) async throws {
        struct Body: Encodable {
            let text: String
            let locale: String
            let segments: [OnDeviceTranscriptSegment]
        }
        let (data, response) = try await perform(
            request("POST", "/v1/rambles/\(rambleId)/transcript",
                    body: Body(text: text, locale: locale, segments: segments))
        )
        try check(response, data: data)
    }

    /// Re-transcribes with the cloud provider and re-runs understanding on the
    /// result. Used by the "higher accuracy" setting and the per-ramble action.
    func upgradeTranscript(rambleId: String) async throws {
        let (data, response) = try await perform(
            request("POST", "/v1/rambles/\(rambleId)/upgrade-transcript")
        )
        try check(response, data: data)
    }

    // MARK: - On-device embeddings

    struct PendingEmbeddings: Decodable {
        struct Unit: Decodable, Identifiable {
            let id: String
            let content: String
        }
        let units: [Unit]
        let dimension: Int
        let expectedRevision: Int

        enum CodingKeys: String, CodingKey {
            case units, dimension
            case expectedRevision = "expected_revision"
        }
    }

    func pendingEmbeddings(limit: Int = 25) async throws -> PendingEmbeddings {
        try await send(request("GET", "/v1/embeddings/pending?limit=\(limit)"), as: PendingEmbeddings.self)
    }

    func uploadEmbeddings(vectors: [(id: String, vector: [Float])], revision: Int) async throws {
        struct Entry: Encodable {
            let id: String
            let vector: [Float]
        }
        struct Body: Encodable {
            let revision: Int
            let vectors: [Entry]
        }
        let body = Body(revision: revision, vectors: vectors.map { Entry(id: $0.id, vector: $0.vector) })
        let (data, response) = try await perform(request("POST", "/v1/embeddings", body: body))
        try check(response, data: data)
    }

    struct HandshakeResult: Decodable {
        let ok: Bool
        let reindexing: Int
    }

    func embeddingHandshake(dimension: Int, revision: Int) async throws -> HandshakeResult {
        struct Body: Encodable {
            let dimension: Int
            let revision: Int
        }
        return try await send(
            request("POST", "/v1/embeddings/handshake", body: Body(dimension: dimension, revision: revision)),
            as: HandshakeResult.self
        )
    }

    // MARK: - Search

    struct SearchResults: Decodable {
        let hits: [SearchHit]
    }

    /// `vector` is the query embedded on this device. Without it the server
    /// falls back to lexical and structured search only.
    func search(_ query: String, vector: [Float]? = nil) async throws -> [SearchHit] {
        struct Body: Encodable {
            let q: String
            let vector: [Float]?
        }
        return try await send(
            request("POST", "/v1/search", body: Body(q: query, vector: vector)),
            as: SearchResults.self
        ).hits
    }

    func ask(_ question: String, vector: [Float]? = nil) async throws -> AskAnswer {
        struct Body: Encodable {
            let question: String
            let vector: [Float]?
        }
        return try await send(
            request("POST", "/v1/ask", body: Body(question: question, vector: vector)),
            as: AskAnswer.self
        )
    }

    func inbox() async throws -> Inbox {
        try await send(request("GET", "/v1/inbox"), as: Inbox.self)
    }

    // MARK: - Entities

    struct EntityList: Decodable { let entities: [EntitySummary] }

    func entities(matching query: String? = nil) async throws -> [EntitySummary] {
        var path = "/v1/entities?limit=100"
        if let query, !query.isEmpty {
            path += "&q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        return try await send(request("GET", path), as: EntityList.self).entities
    }

    func entity(id: String) async throws -> EntityPage {
        try await send(request("GET", "/v1/entities/\(id)"), as: EntityPage.self)
    }

    // MARK: - Actions

    func confirmAction(id: String) async throws {
        let (data, response) = try await perform(request("POST", "/v1/actions/\(id)/confirm"))
        try check(response, data: data)
    }

    func cancelAction(id: String) async throws {
        let (data, response) = try await perform(request("POST", "/v1/actions/\(id)/cancel"))
        try check(response, data: data)
    }

    struct DeviceActionList: Decodable { let actions: [DeviceAction] }

    func pendingDeviceActions() async throws -> [DeviceAction] {
        try await send(request("GET", "/v1/actions/pending-device"), as: DeviceActionList.self).actions
    }

    func reportActionResult(id: String, success: Bool, result: [String: String], error: String?) async throws {
        struct Body: Encodable {
            let success: Bool
            let result: [String: String]
            let error: String?
        }
        let (data, response) = try await perform(
            request("POST", "/v1/actions/\(id)/result",
                    body: Body(success: success, result: result, error: error))
        )
        try check(response, data: data)
    }

    // MARK: - Legal

    struct LegalLinks: Decodable {
        let privacyURL: String
        let termsURL: String
        let lastUpdated: String
        /// False while the policy still carries publisher placeholders, so the
        /// app can say so rather than presenting an unfinished document as final.
        let complete: Bool

        enum CodingKeys: String, CodingKey {
            case privacyURL = "privacy_url"
            case termsURL = "terms_url"
            case lastUpdated = "last_updated"
            case complete
        }
    }

    func legal() async throws -> LegalLinks {
        try await send(request("GET", "/v1/legal", authenticated: false), as: LegalLinks.self)
    }

    // MARK: - Your data

    /// Everything the server holds about this account, as JSON. The privacy
    /// policy promises this is reachable from inside the app, so it is.
    func exportEverything() async throws -> Data {
        let (data, response) = try await perform(request("GET", "/v1/me/export"))
        try check(response, data: data)
        return data
    }

    /// Irreversible. Removes every recording, every audio file, and the account.
    func deleteAccount() async throws {
        struct Body: Encodable { let confirm: String }
        let (data, response) = try await perform(
            request("DELETE", "/v1/me", body: Body(confirm: "DELETE"))
        )
        try check(response, data: data)
        setToken(nil)
    }

    // MARK: - Integrations

    struct IntegrationList: Decodable {
        struct Item: Decodable, Identifiable, Hashable {
            let provider: String
            let name: String
            let category: String
            let connect: String
            let available: Bool
            let status: String
            var id: String { provider }
        }
        let integrations: [Item]
    }

    func integrations() async throws -> [IntegrationList.Item] {
        try await send(request("GET", "/v1/integrations"), as: IntegrationList.self).integrations
    }

    func connectIntegration(_ provider: String) async throws {
        let (data, response) = try await perform(
            request("POST", "/v1/integrations/\(provider)/connect")
        )
        try check(response, data: data)
    }

    func disconnectIntegration(_ provider: String) async throws {
        let (data, response) = try await perform(request("DELETE", "/v1/integrations/\(provider)"))
        try check(response, data: data)
    }
}

// MARK: - Helpers

/// Lets `request(body:)` accept any Encodable without a generic parameter.
private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        encode = wrapped.encode
    }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

enum UIDeviceName {
    static var current: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        "unknown"
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif
