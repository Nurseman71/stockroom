//
//  Box.swift
//  Stockroom
//
//  The box record, byte-compatible with the web app (index.html) and the
//  sync server (storage_tracker_server.py). Three rules keep the two apps
//  from corrupting each other's data:
//
//  1. Unknown keys are preserved. If the web app ever adds a field, saving
//     a box from the phone must not silently strip it — `extras` carries
//     anything this file doesn't name and writes it back out untouched.
//  2. `updatedAt` stays a String in the exact format JavaScript's
//     `toISOString()` produces (UTC, millisecond precision, trailing Z).
//     The server picks the winner of a merge by comparing these strings
//     lexicographically, so the format IS the ordering.
//  3. Ids use the web app's scheme: "b_" + base36(ms) + "_" + 6 base36.
//  4. Photos (Oct 2026: up to 6 per box). `photos` lists filenames, cover
//     first; `photoFilename` is always written as photos[0] (or null) so
//     older clients still show the cover. A box's original photo is
//     "<id>.jpg" and every later one "<id>-<suffix>.jpg" — the same
//     ownership rule the server enforces (photo_belongs_to).
//

import Foundation

/// Any JSON value, so fields this app doesn't model survive a round trip.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

nonisolated struct Box: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var box: String
    var contents: String
    var location: String
    var tags: [String]
    /// Photo filenames, cover first. Only names this box owns.
    var photos: [String] {
        didSet { photos = Self.ownedPhotos(photos, id: id) }
    }
    var updatedAt: String
    var deleted: Bool
    /// Every key in the JSON that isn't one of the above.
    var extras: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = [
        "id", "box", "contents", "location", "tags", "photoFilename", "photos", "updatedAt", "deleted",
    ]

    /// Matches the web app and the server.
    static let maxPhotos = 6

    /// The cover photo — what older clients know as the box's only photo.
    var photoFilename: String? { photos.first }

    /// A brand-new, unsaved box with a fresh web-compatible id.
    static func blank(boxNumber: String = "", location: String = "") -> Box {
        Box(id: makeID(), box: boxNumber, contents: "", location: location, tags: [],
            photoFilename: nil, updatedAt: Timestamp.now(), deleted: false)
    }

    init(id: String, box: String, contents: String, location: String, tags: [String],
         photoFilename: String? = nil, photos: [String] = [], updatedAt: String, deleted: Bool,
         extras: [String: JSONValue] = [:]) {
        self.id = id; self.box = box; self.contents = contents; self.location = location
        self.tags = tags; self.updatedAt = updatedAt
        self.deleted = deleted; self.extras = extras
        self.photos = Self.mergedPhotos(photos, cover: photoFilename, id: id)
    }

    // MARK: Photo names

    /// A fresh, never-reused filename for another photo of box `id`:
    /// "<id>-<suffix>.jpg", suffix 1–16 base36 chars (server: PHOTO_KEY_RE).
    static func newPhotoName(for id: String, now: Date = Date()) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let ms = String(Int64((now.timeIntervalSince1970 * 1000).rounded(.down)), radix: 36)
        let suffix = String(ms.suffix(5)) + String((0..<4).map { _ in alphabet.randomElement()! })
        return "\(id)-\(suffix).jpg"
    }

    /// True if `name` is a photo filename owned by box `id` — the server's
    /// photo_belongs_to rule, so a box can never claim another box's photo.
    static func owns(_ name: String, id: String) -> Bool {
        guard !id.isEmpty, name.hasSuffix(".jpg") else { return false }
        let key = name.dropLast(4)
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        func ascii(_ s: Substring, underscore: Bool) -> Bool {
            let allowed = underscore ? Self.photoKeyCharacters : Self.photoSuffixCharacters
            return s.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        let valid: Bool
        switch parts.count {
        case 1: valid = (1...64).contains(parts[0].count) && ascii(parts[0], underscore: true)
        case 2: valid = (1...64).contains(parts[0].count) && ascii(parts[0], underscore: true)
                    && (1...16).contains(parts[1].count) && ascii(parts[1], underscore: false)
        default: valid = false
        }
        return valid && (key == Substring(id) || key.hasPrefix(id + "-"))
    }

    private static let photoSuffixCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let photoKeyCharacters = photoSuffixCharacters.union(CharacterSet(charactersIn: "_"))

    /// The list as stored: owned names only, no duplicates, order kept.
    static func ownedPhotos(_ names: [String], id: String) -> [String] {
        var seen: Set<String> = []
        return names.filter { owns($0, id: id) && seen.insert($0).inserted }
    }

    /// `photoFilename` from an older client goes in front if the list lacks it.
    static func mergedPhotos(_ names: [String], cover: String?, id: String) -> [String] {
        var all = names
        if let cover, !all.contains(cover) { all.insert(cover, at: 0) }
        return ownedPhotos(all, id: id)
    }

    /// Mirrors index.html: 'b_' + Date.now().toString(36) + '_' + 6 random base36 chars.
    static func makeID(now: Date = Date()) -> String {
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded(.down))
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let suffix = String((0..<6).map { _ in alphabet.randomElement()! })
        return "b_" + String(ms, radix: 36) + "_" + suffix
    }

    // MARK: Codable — tolerant in, faithful out

    nonisolated private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)

        // Strings that might have been written as numbers (e.g. box: 4).
        func text(_ name: String) -> String? {
            let k = Key(name)
            if let s = try? c.decode(String.self, forKey: k) { return s }
            if let d = try? c.decode(Double.self, forKey: k) {
                return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
            }
            return nil
        }

        // A record with no id is unusable (the server drops those too); it
        // decodes with an empty id and callers filter it out, rather than
        // throwing and losing the whole array.
        id = text("id") ?? ""
        box = text("box") ?? ""
        contents = text("contents") ?? ""
        location = text("location") ?? ""
        tags = (try? c.decode([String].self, forKey: Key("tags"))) ?? []
        let cover = try? c.decode(String.self, forKey: Key("photoFilename"))
        let list: [String] = (try? c.decode([JSONValue].self, forKey: Key("photos")))?
            .compactMap { (value: JSONValue) -> String? in
                if case .string(let s) = value { return s }
                return nil
            } ?? []
        updatedAt = text("updatedAt") ?? ""
        deleted = (try? c.decode(Bool.self, forKey: Key("deleted"))) ?? false
        photos = Self.mergedPhotos(list, cover: cover, id: id)

        var extras: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try? c.decode(JSONValue.self, forKey: key)
        }
        self.extras = extras
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (key, value) in extras where !Self.knownKeys.contains(key) {
            try c.encode(value, forKey: Key(key))
        }
        try c.encode(id, forKey: Key("id"))
        try c.encode(box, forKey: Key("box"))
        try c.encode(contents, forKey: Key("contents"))
        try c.encode(location, forKey: Key("location"))
        try c.encode(tags, forKey: Key("tags"))
        try c.encode(photos, forKey: Key("photos"))
        if let photoFilename {
            try c.encode(photoFilename, forKey: Key("photoFilename"))   // always photos[0]
        } else {
            try c.encodeNil(forKey: Key("photoFilename"))   // web app writes null, not absent
        }
        try c.encode(updatedAt, forKey: Key("updatedAt"))
        // Always explicit. The web app's tombstone-edit bug comes from an
        // edit that omits `deleted` and inherits `true` via object spread;
        // writing false outright means a phone edit never has that problem.
        try c.encode(deleted, forKey: Key("deleted"))
    }
}

/// Timestamps in exactly JavaScript's `new Date().toISOString()` format:
/// "2026-10-16T16:11:00.123Z". The server compares these as strings.
nonisolated enum Timestamp {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    static func now() -> String { string(from: Date()) }

    static func string(from date: Date) -> String { date.formatted(withFraction) }

    static func date(from string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? withoutFraction.parse(string))
    }
}
