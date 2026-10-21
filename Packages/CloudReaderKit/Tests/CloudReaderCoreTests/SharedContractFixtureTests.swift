import Foundation
import XCTest
@testable import CloudReaderCore

final class SharedContractFixtureTests: XCTestCase {
    private let fixtureNames = [
        "deletion-equal-time", "full-record", "invalid-number", "malformed-hash",
        "minimal-legacy", "mixed-case-uuid", "nested-unknown", "numeric-overflow",
        "out-of-range-progress", "unknown-format", "unknown-role", "unsafe-filename",
        "unsupported-version"
    ]

    private func fixture(_ name: String, extension ext: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../Contracts/v1/fixtures/\(name).\(ext)")
            .standardizedFileURL
        return try Data(contentsOf: url)
    }

    func testAllSharedFixturePairsHaveAppleClassification() throws {
        XCTAssertEqual(fixtureNames.count, 13)
        for name in fixtureNames {
            let expectationData = try fixture(name, extension: "expected.json")
            let expectation = try XCTUnwrap(JSONSerialization.jsonObject(with: expectationData) as? [String: Any])
            let classification = try XCTUnwrap(expectation["classification"] as? String)
            let input = try fixture(name, extension: "json")

            let normalizedClassification = classification.lowercased()
            let expectsRejection = normalizedClassification.hasPrefix("reject") ||
                normalizedClassification.contains("rejection expectation")
            if expectsRejection {
                var rejected = false
                do {
                    let manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: input)
                    do {
                        try manifest.validateForRemoteSync()
                    } catch {
                        rejected = true
                    }
                } catch {
                    // Decode-time rejection is expected for malformed numeric values,
                    // unsupported versions, and the current closed BookFormat enum.
                    rejected = true
                }
                XCTAssertTrue(rejected, "\(name): \(classification)")
            } else {
                let manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: input)
                try manifest.validateForRemoteSync()
                if name == "minimal-legacy" {
                    let book = try XCTUnwrap(manifest.books.first?.book)
                    XCTAssertEqual(book.progress, 0)
                    XCTAssertFalse(book.isBookmarked)
                    XCTAssertEqual(book.modifiedAt, book.addedAt)
                    XCTAssertNil(book.lastOpenedAt)
                }
                if name == "unknown-role" {
                    XCTAssertEqual(manifest.conversations.first?.messages.first?.role, .unknown("tool"))
                }
                if name == "deletion-equal-time" {
                    XCTAssertTrue(normalizedClassification.contains("characterization"))
                }
            }
        }
    }

    func testRemotePreflightRejectsMalformedMetadata() throws {
        for name in ["malformed-hash", "unsafe-filename", "out-of-range-progress"] {
            let data = try fixture(name, extension: "json")
            let manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: data)
            XCTAssertThrowsError(try manifest.validateForRemoteSync(), "\(name)")
        }
    }

    func testNestedUnknownFixtureRoundTripsAndPreflightAcceptsIt() throws {
        let data = try fixture("nested-unknown", extension: "json")
        let manifest = try JSONDecoder().decode(RemoteLibraryManifest.self, from: data)
        try manifest.validateForRemoteSync()
        let encoded = try JSONEncoder().encode(manifest)
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((source["futureRoot"] as? [String: Any])?["futureNull"] as? NSNull,
                       (result["futureRoot"] as? [String: Any])?["futureNull"] as? NSNull)
        XCTAssertNotNil((result["books"] as? [[String: Any]])?.first?["futureEntry"])
    }
}
