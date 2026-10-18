//
//  StockroomAPI.swift
//  Stockroom
//
//  Thin client for storage_tracker_server.py. Endpoints, as the server
//  defines them:
//
//    GET  /api/data?token=…              -> {"items": [...]}
//    POST /api/data?token=…              {"items": [...]} -> merged {"items": [...]}
//    GET  /photos/<name>.jpg?token=…     -> JPEG
//    POST /api/photos/<name>?token=…     {"data": "data:image/jpeg;base64,…"}
//    POST /api/identify-photo?token=…    {"photos": ["data:…", …], "data": "data:…"} -> {"items": "…"}
//
//  A photo <name> is "<box id>" (a box's original photo) or
//  "<box id>-<suffix>" (each further one); see Box.newPhotoName.
//
//  The token rides in the query string because that is what the server
//  accepts (a header would have meant a CORS preflight for the web app).
//  Only HTTPS base URLs are accepted — see ServerConfig — so it is never
//  sent in the clear. The Gemini key never leaves the Mac.
//

import Foundation

nonisolated enum APIError: LocalizedError, Equatable {
    case unauthorized
    case tooLarge
    case offline(String)
    case server(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "The server rejected the sync token. Check it in Settings."
        case .tooLarge: "That photo is too large for the server (10 MB limit)."
        case .offline(let why): "Can't reach your Mac: \(why)"
        case .server(let code, let message): "Server error \(code): \(message)"
        case .badResponse: "The server sent a response the app didn't understand."
        }
    }
}

nonisolated struct ServerConfig: Sendable, Equatable {
    let baseURL: URL
    let token: String

    /// Accepts "https://host[:port]" with or without a trailing slash.
    /// Plain http is refused outright: the token is in the URL, and the
    /// Tailscale HTTPS address already has a valid certificate.
    static func validatedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s),
              url.scheme?.lowercased() == "https",
              let host = url.host(), !host.isEmpty,
              url.query == nil else { return nil }
        return url
    }
}

nonisolated struct ItemsEnvelope: Codable, Sendable {
    var items: [Box]
}

nonisolated struct StockroomAPI: Sendable {
    let config: ServerConfig

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral   // no on-disk HTTP cache of token-bearing URLs
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false              // fail fast; the store queues and retries
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    private nonisolated struct ErrorBody: Decodable { let error: String }
    private nonisolated struct PhotoBody: Encodable { let data: String }
    private nonisolated struct IdentifyBody: Encodable { let photos: [String]; let data: String }
    private nonisolated struct IdentifyResult: Decodable { let items: String }

    // MARK: Endpoints

    func fetchAll() async throws -> [Box] {
        let data = try await send(request("api/data"))
        return try decodeItems(data)
    }

    /// Sends local items; the server merges (newest updatedAt wins per id)
    /// and returns the full merged set.
    func push(_ items: [Box]) async throws -> [Box] {
        var req = request("api/data", method: "POST")
        req.httpBody = try JSONEncoder().encode(ItemsEnvelope(items: items))
        return try decodeItems(try await send(req))
    }

    /// `filename` is "<key>.jpg"; the endpoint takes the key.
    func uploadPhoto(filename: String, jpeg: Data) async throws {
        let key = filename.hasSuffix(".jpg") ? String(filename.dropLast(4)) : filename
        var req = request("api/photos/\(key)", method: "POST")
        req.httpBody = try JSONEncoder().encode(PhotoBody(data: Self.dataURL(jpeg)))
        req.timeoutInterval = 60
        _ = try await send(req)
    }

    func downloadPhoto(filename: String) async throws -> Data {
        try await send(request("photos/\(filename)"))
    }

    /// Returns Gemini's suggestion text, one item per line. All of a box's
    /// photos go in one request so an item seen twice is named once.
    func identify(jpegs: [Data]) async throws -> String {
        let urls = jpegs.map(Self.dataURL)
        var req = request("api/identify-photo", method: "POST")
        // `data` too, for a server that predates multi-photo boxes.
        req.httpBody = try JSONEncoder().encode(IdentifyBody(photos: urls, data: urls.first ?? ""))
        req.timeoutInterval = 90
        let data = try await send(req)
        guard let result = try? JSONDecoder().decode(IdentifyResult.self, from: data) else {
            throw APIError.badResponse
        }
        return result.items
    }

    // MARK: Plumbing

    static func dataURL(_ jpeg: Data) -> String {
        "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var components = URLComponents(
            url: config.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: config.token)]
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        if method == "POST" { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return req
    }

    private func decodeItems(_ data: Data) throws -> [Box] {
        guard let env = try? JSONDecoder().decode(ItemsEnvelope.self, from: data) else {
            throw APIError.badResponse
        }
        return env.items.filter { !$0.id.isEmpty }
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let result: (Data, URLResponse)
        do {
            result = try await Self.session.data(for: req)
        } catch let error as URLError {
            throw APIError.offline(error.localizedDescription)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.unauthorized
        case 413:
            throw APIError.tooLarge
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw APIError.server(http.statusCode, message)
        }
    }
}
