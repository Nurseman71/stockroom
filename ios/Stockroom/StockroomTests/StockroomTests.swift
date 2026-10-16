//
//  StockroomTests.swift
//  StockroomTests
//
//  Pins the wire format to what index.html and storage_tracker_server.py
//  expect. If one of these fails, the phone and the web app would start
//  overwriting each other's data — fix the code, not the test.
//

import Foundation
import Testing
@testable import Stockroom

struct WireFormatTests {

    @Test func timestampMatchesJavaScriptToISOString() throws {
        let s = Timestamp.now()
        let pattern = try Regex(#"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#)
        #expect(s.wholeMatch(of: pattern) != nil, "got \(s)")
        #expect(Timestamp.date(from: s) != nil)
    }

    @Test func timestampsOrderLexicographically() {
        let a = Timestamp.string(from: Date(timeIntervalSince1970: 1_000))
        let b = Timestamp.string(from: Date(timeIntervalSince1970: 1_000.5))
        #expect(a < b)   // the server's merge relies on string comparison
    }

    @Test func idMatchesWebScheme() throws {
        let id = Box.makeID(now: Date(timeIntervalSince1970: 1_756_239_137.669))
        let pattern = try Regex(#"^b_[0-9a-z]+_[0-9a-z]{6}$"#)
        #expect(id.wholeMatch(of: pattern) != nil, "got \(id)")
        #expect(id.hasPrefix("b_" + String(Int64(1_756_239_137_669), radix: 36) + "_"))
    }

    @Test func roundTripPreservesUnknownFieldsAndNulls() throws {
        let json = #"""
        {"id":"b_abc_123456","box":"4","contents":"Router","location":"Garage",
         "tags":["Test"],"photoFilename":null,"updatedAt":"2026-08-26T20:12:17.669Z",
         "deleted":true,"futureField":{"a":[1,"x",false]}}
        """#
        let box = try JSONDecoder().decode(Box.self, from: Data(json.utf8))
        #expect(box.deleted)
        #expect(box.photoFilename == nil)
        #expect(box.extras["futureField"] != nil)

        let out = try JSONSerialization.jsonObject(with: JSONEncoder().encode(box)) as! [String: Any]
        #expect(out["photoFilename"] is NSNull)          // null, not missing
        #expect(out["futureField"] != nil)                // not stripped
        #expect(out["updatedAt"] as? String == "2026-08-26T20:12:17.669Z")
        #expect(out["deleted"] as? Bool == true)
    }

    @Test func tolerantDecoding() throws {
        // A numeric box number and a missing tags array must not reject the record.
        let json = #"{"id":"b_x_aaaaaa","box":7,"updatedAt":"2026-01-01T00:00:00.000Z"}"#
        let box = try JSONDecoder().decode(Box.self, from: Data(json.utf8))
        #expect(box.box == "7")
        #expect(box.tags.isEmpty)
        #expect(box.deleted == false)
    }

    @Test func serverURLValidationRequiresHTTPS() {
        #expect(ServerConfig.validatedURL("https://mac.tailnet.ts.net:8788/") != nil)
        #expect(ServerConfig.validatedURL("http://mac.tailnet.ts.net:8788") == nil)
        #expect(ServerConfig.validatedURL("mac.tailnet.ts.net") == nil)
        #expect(ServerConfig.validatedURL("https://mac.ts.net?token=abc") == nil)
    }
}

struct LabelCodeTests {
    @Test func readsBoxIDFromPrintedLabel() {
        #expect(LabelCode.boxID(from: "https://mac.tailnet.ts.net:8788/?boxid=b_mtg0irgd_o05xzc") == "b_mtg0irgd_o05xzc")
        #expect(LabelCode.boxID(from: "https://nurseman71.github.io/stockroom/?boxid=b_x_aaaaaa") == "b_x_aaaaaa")
    }

    @Test func rejectsOtherCodes() {
        #expect(LabelCode.boxID(from: "https://example.com/") == nil)
        #expect(LabelCode.boxID(from: "hello world") == nil)
        #expect(LabelCode.boxID(from: "https://x.ts.net/?boxid=") == nil)
        #expect(LabelCode.boxID(from: "https://x.ts.net/?boxid=..%2F..%2Fetc") == nil)
    }
}

struct LabelPrintingTests {
    @Test func labelLinkRoundTripsThroughScanner() {
        let link = LabelCode.link(base: "https://mac.tailnet.ts.net/stockroom/", id: "b_mtg0irgd_o05xzc")
        #expect(link == "https://mac.tailnet.ts.net/stockroom/?boxid=b_mtg0irgd_o05xzc")   // same shape the web app prints
        #expect(LabelCode.boxID(from: link) == "b_mtg0irgd_o05xzc")
    }

    @Test func qrHasFinderPatternsInTheRightCorners() {
        // Finder patterns must be top-left, top-right, bottom-left. A
        // vertically mirrored code (bottom-right finder) won't scan.
        let m = QRMatrix.modules(for: "https://mac.tailnet.ts.net/stockroom/?boxid=b_mtg0irgd_o05xzc")
        let n = m.count
        #expect(n >= 21 && (n - 17) % 4 == 0, "not a valid QR size: \(n)")
        #expect(m.allSatisfy { $0.count == n })
        #expect(QRMatrix.hasFinder(m, atRow: 0, col: 0))
        #expect(QRMatrix.hasFinder(m, atRow: 0, col: n - 7))
        #expect(QRMatrix.hasFinder(m, atRow: n - 7, col: 0))
        #expect(!QRMatrix.hasFinder(m, atRow: n - 7, col: n - 7))
    }
}
