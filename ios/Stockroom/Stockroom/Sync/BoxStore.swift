//
//  BoxStore.swift
//  Stockroom
//
//  The single source of truth on the phone. Works fully offline: every
//  change is written to disk immediately and queued; sync() pushes the
//  queue to the Mac whenever it's reachable over Tailscale.
//
//  Sync mirrors the server's own rule (merge_items): per id, the newest
//  updatedAt wins, compared as strings. Deletes are tombstones
//  (deleted: true), never removals, so a delete made offline still wins
//  against an older copy on the server.
//
//  Photos are plain files in Application Support, so unlike the web app's
//  localStorage cache there is no ~25–30 box ceiling.
//

import Foundation
import Observation

@Observable
final class BoxStore {
    enum SyncState: Equatable {
        case notConfigured
        case idle
        case syncing
        case offline(String)
        case failed(String)
    }

    // MARK: Observable state

    /// Everything, tombstones included. UI should use `visibleBoxes`.
    private(set) var boxes: [Box] = []
    private(set) var syncState: SyncState = .notConfigured
    private(set) var lastSynced: Date?
    /// Box ids edited on this phone and not yet confirmed by the server.
    private(set) var pendingIDs: Set<String> = []
    /// Photos taken on this phone and not yet uploaded.
    private(set) var pendingPhotoIDs: Set<String> = []
    /// Per-box counter, bumped when that box's photo file changes, so only
    /// the views showing that photo reload (a single global counter made
    /// every row restart — and cancel — its download whenever any finished).
    private(set) var photoRevisions: [String: Int] = [:]

    private(set) var serverURLString: String
    private(set) var hasToken: Bool

    var visibleBoxes: [Box] { boxes.filter { !$0.deleted } }
    var hasUnsyncedChanges: Bool { !pendingIDs.isEmpty || !pendingPhotoIDs.isEmpty }
    var isConfigured: Bool { isPreview || config != nil }

    // MARK: Private

    private var photoVersions: [String: String] = [:]   // id -> box.updatedAt the local photo file matches
    private var downloadsInFlight: Set<String> = []
    private var isSyncing = false
    private var syncRequestedDuringFlight = false

    private static let urlDefaultsKey = "serverURL"
    private static let tokenAccount = "syncToken"
    private static let tombstoneMaxAge: TimeInterval = 30 * 24 * 3600   // matches server

    /// Previews only: an in-memory store that never touches disk, Keychain or network.
    private var isPreview = false

    private var config: ServerConfig? {
        guard !isPreview, let url = ServerConfig.validatedURL(serverURLString),
              let token = Keychain.read(Self.tokenAccount), !token.isEmpty else { return nil }
        return ServerConfig(baseURL: url, token: token)
    }

    init() {
        serverURLString = UserDefaults.standard.string(forKey: Self.urlDefaultsKey) ?? ""
        hasToken = !(Keychain.read(Self.tokenAccount) ?? "").isEmpty
        loadCache()
        syncState = isConfigured ? .idle : .notConfigured
    }

    #if DEBUG
    init(previewBoxes: [Box]) {
        serverURLString = "https://preview.example.ts.net:8788"
        hasToken = true
        isPreview = true
        boxes = previewBoxes
        syncState = .idle
    }
    #endif

    // MARK: Settings

    enum ConfigError: LocalizedError {
        case badURL
        case emptyToken
        var errorDescription: String? {
            switch self {
            case .badURL: "Use your Mac's Tailscale HTTPS address, e.g. https://your-mac.your-tailnet.ts.net:8788"
            case .emptyToken: "Paste the sync token from stockroom_token.txt."
            }
        }
    }

    /// Saves the server address (UserDefaults — not secret) and the token
    /// (Keychain). Pass nil for token to keep the existing one.
    func configure(serverURL: String, token: String?) throws {
        guard let url = ServerConfig.validatedURL(serverURL) else { throw ConfigError.badURL }
        if let token {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ConfigError.emptyToken }
            Keychain.write(trimmed, account: Self.tokenAccount)
            hasToken = true
        } else if !hasToken {
            throw ConfigError.emptyToken
        }
        serverURLString = url.absoluteString
        UserDefaults.standard.set(serverURLString, forKey: Self.urlDefaultsKey)
        syncState = .idle
        requestSync()
    }

    /// Forgets the token. Local boxes stay on the phone.
    func signOut() {
        Keychain.delete(Self.tokenAccount)
        hasToken = false
        syncState = .notConfigured
    }

    // MARK: Editing (all offline-safe)

    /// Inserts or updates a box. Stamps it now and clears any tombstone,
    /// so an edit always resurrects (deliberately — see Box.encode).
    func save(_ box: Box) {
        var b = box
        b.updatedAt = Timestamp.now()
        b.deleted = false
        b.box = b.box.trimmingCharacters(in: .whitespacesAndNewlines)
        b.location = b.location.trimmingCharacters(in: .whitespacesAndNewlines)
        b.tags = Self.cleanTags(b.tags)
        apply(b)
    }

    func delete(id: String) {
        guard var b = boxes.first(where: { $0.id == id }) else { return }
        b.deleted = true
        b.updatedAt = Timestamp.now()
        apply(b)
    }

    func box(id: String) -> Box? {
        boxes.first { $0.id == id && !$0.deleted }
    }

    /// Stores a JPEG for `box` and queues the upload. Returns the box with
    /// photoFilename set; the caller still save()s it with its other edits.
    func attachPhoto(_ jpeg: Data, to box: Box) throws -> Box {
        try jpeg.write(to: Self.photoFile(box.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var b = box
        b.photoFilename = b.expectedPhotoFilename
        pendingPhotoIDs.insert(b.id)
        bumpPhoto(b.id)
        persist()
        return b
    }

    /// Detaches the photo. The server keeps its file (it has no delete
    /// endpoint) and prunes it with the box's tombstone.
    func removePhoto(from box: Box) -> Box {
        try? FileManager.default.removeItem(at: Self.photoFile(box.id))
        pendingPhotoIDs.remove(box.id)
        photoVersions[box.id] = nil
        bumpPhoto(box.id)
        var b = box
        b.photoFilename = nil
        return b
    }

    // MARK: Photos

    /// The on-disk photo for a box, if one has been taken here or downloaded.
    func localPhotoURL(for box: Box) -> URL? {
        guard box.photoFilename != nil else { return nil }
        let url = Self.photoFile(box.id)
        // percentEncoded: false matters — "Application Support" has a space,
        // and the encoded form ("%20") names a file that doesn't exist.
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Downloads a box's photo if the local copy is missing or older than
    /// the box. Same cache-busting rule as the web app's photoSrc(): a
    /// changed updatedAt means the photo may have changed.
    func refreshPhotoIfNeeded(for box: Box) async {
        guard box.photoFilename != nil,
              !pendingPhotoIDs.contains(box.id),           // never overwrite an unuploaded photo
              !downloadsInFlight.contains(box.id),         // thumbnail + detail share one download
              photoVersions[box.id] != box.updatedAt || localPhotoURL(for: box) == nil,
              let api = config.map(StockroomAPI.init) else { return }
        downloadsInFlight.insert(box.id)
        defer { downloadsInFlight.remove(box.id) }
        do {
            let data = try await api.downloadPhoto(id: box.id)
            try data.write(to: Self.photoFile(box.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            photoVersions[box.id] = box.updatedAt
            bumpPhoto(box.id)
            persist()
        } catch {
            // Offline or 404: keep whatever copy we have.
        }
    }

    func photoRevision(for id: String) -> Int { photoRevisions[id, default: 0] }

    private func bumpPhoto(_ id: String) { photoRevisions[id, default: 0] += 1 }

    /// Server-side Gemini identification. Throws APIError.
    func identifyItems(in jpeg: Data) async throws -> String {
        guard let config else { throw APIError.unauthorized }
        return try await StockroomAPI(config: config).identify(jpeg: jpeg)
    }

    // MARK: Sync

    /// Fire-and-forget sync, coalesced if one is already running.
    func requestSync() {
        Task { await sync() }
    }

    /// Call from a view's .task: syncs now and every `interval` while alive.
    func runAutoSync(every interval: Duration = .seconds(30)) async {
        while !Task.isCancelled {
            await sync()
            try? await Task.sleep(for: interval)
        }
    }

    func sync() async {
        guard !isPreview else { return }
        guard let config else { syncState = .notConfigured; return }
        guard !isSyncing else { syncRequestedDuringFlight = true; return }
        isSyncing = true
        syncState = .syncing
        defer { isSyncing = false }

        let api = StockroomAPI(config: config)
        do {
            // 1. Photos first, so a box never points at a photo the server
            //    doesn't have yet.
            for id in pendingPhotoIDs.sorted() {
                guard let b = boxes.first(where: { $0.id == id }), !b.deleted,
                      let data = try? Data(contentsOf: Self.photoFile(id)) else {
                    pendingPhotoIDs.remove(id)
                    continue
                }
                try await api.uploadPhoto(id: id, jpeg: data)
                pendingPhotoIDs.remove(id)
                photoVersions[id] = b.updatedAt
                persist()
            }

            // 2. Push everything; the server merges and returns the result.
            let sentStamps = Dictionary(boxes.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
            let merged = try await api.push(boxes)

            // 3. Adopt the server's view, but keep anything edited on this
            //    phone while the request was in flight.
            var result = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var stillPending: Set<String> = []
            for local in boxes where sentStamps[local.id] != local.updatedAt {
                if let server = result[local.id], server.updatedAt > local.updatedAt { continue }
                result[local.id] = local
                stillPending.insert(local.id)
            }
            boxes = Array(result.values)
            pendingIDs = stillPending
            lastSynced = Date()
            syncState = .idle
            persist()
        } catch let error as APIError {
            if case .offline(let why) = error { syncState = .offline(why) }
            else { syncState = .failed(error.localizedDescription) }
            persist()
        } catch {
            syncState = .failed(error.localizedDescription)
            persist()
        }

        // Edits made while the request was in flight go out straight away —
        // but only after a success, so being offline never spins a loop.
        let goAgain = syncRequestedDuringFlight || hasUnsyncedChanges
        syncRequestedDuringFlight = false
        if goAgain && syncState == .idle { requestSync() }
    }

    // MARK: Derived lists for the UI

    /// Distinct locations, merging case/whitespace variants (same rule as
    /// the web app's Phase 3 grouping), most-used spelling wins.
    var allLocations: [String] {
        Self.distinctPreferringCommon(visibleBoxes.map(\.location))
    }

    var allTags: [String] {
        Self.distinctPreferringCommon(visibleBoxes.flatMap(\.tags))
    }

    /// One more than the highest numeric box number in use.
    var suggestedNextBoxNumber: String {
        let numbers = visibleBoxes.compactMap { Int($0.box) }
        return String((numbers.max() ?? 0) + 1)
    }

    nonisolated static func normalizedKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased()
    }

    private static func distinctPreferringCommon(_ values: [String]) -> [String] {
        var counts: [String: [String: Int]] = [:]
        for v in values {
            let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            counts[normalizedKey(trimmed), default: [:]][trimmed, default: 0] += 1
        }
        return counts.values
            .compactMap { spellings in spellings.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func cleanTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { tag in
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(normalizedKey(t)).inserted else { return nil }
            return t
        }
    }

    // MARK: Internals

    private func apply(_ box: Box) {
        if let i = boxes.firstIndex(where: { $0.id == box.id }) { boxes[i] = box }
        else { boxes.append(box) }
        pendingIDs.insert(box.id)
        persist()
        requestSync()
    }

    // MARK: Disk

    private nonisolated struct CacheFile: Codable {
        var items: [Box]
        var pendingIDs: [String]
        var pendingPhotoIDs: [String]
        var photoVersions: [String: String]
        var lastSynced: Date?
    }

    private static var rootDirectory: URL {
        let url = URL.applicationSupportDirectory.appending(path: "Stockroom", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var cacheFileURL: URL { rootDirectory.appending(path: "boxes.json") }

    static func photoFile(_ id: String) -> URL {
        let dir = rootDirectory.appending(path: "Photos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(id).jpg")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheFileURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-Self.tombstoneMaxAge)
        boxes = cache.items.filter { b in
            guard !b.id.isEmpty else { return false }
            guard b.deleted, let when = Timestamp.date(from: b.updatedAt) else { return true }
            return when >= cutoff || cache.pendingIDs.contains(b.id)
        }
        pendingIDs = Set(cache.pendingIDs)
        pendingPhotoIDs = Set(cache.pendingPhotoIDs)
        photoVersions = cache.photoVersions
        lastSynced = cache.lastSynced
    }

    private func persist() {
        guard !isPreview else { return }
        let cache = CacheFile(items: boxes, pendingIDs: pendingIDs.sorted(),
                              pendingPhotoIDs: pendingPhotoIDs.sorted(),
                              photoVersions: photoVersions, lastSynced: lastSynced)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.cacheFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
