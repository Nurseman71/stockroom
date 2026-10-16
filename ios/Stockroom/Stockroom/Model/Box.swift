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
    var photoFilename: String?
    var updatedAt: String
    var deleted: Bool
    /// Every key in the JSON that isn't one of the above.
    var extras: [String: JSONValue] = [:]

    static let knownKeys: Set<String> = [
        "id", "box", "contents", "location", "tags", "photoFilename", "updatedAt", "deleted",
    ]

    /// The filename the server stores a box's photo under (photo_path_for_id).
    var expectedPhotoFilename: String { "\(id).jpg" }

    /// A brand-new, unsaved box with a fresh web-compatible id.
    static func blank(boxNumber: String = "", location: String = "") -> Box {
        Box(id: makeID(), box: boxNumber, contents: "", location: location, tags: [],
            photoFilename: nil, updatedAt: Timestamp.now(), deleted: false)
    }

    init(id: String, box: String, contents: String, location: String, tags: [String],
         photoFilename: String?, updatedAt: String, deleted: Bool,
         extras: [String: JSONValue] = [:]) {
        self.id = id; self.box = box; self.contents = contents; self.location = location
        self.tags = tags; self.photoFilename = photoFilename; self.updatedAt = updatedAt
        self.deleted = deleted; self.extras = extras
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
        photoFilename = try? c.decode(String.self, forKey: Key("photoFilename"))
        updatedAt = text("updatedAt") ?? ""
        deleted = (try? c.decode(Bool.self, forKey: Key("deleted"))) ?? false

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
        if let photoFilename {
            try c.encode(photoFilename, forKey: Key("photoFilename"))
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
