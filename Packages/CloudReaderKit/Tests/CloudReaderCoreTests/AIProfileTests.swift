import Foundation
import XCTest
import CloudReaderCore

private struct FixedProfileSource: AIProfileSource {
    let profile: AIProviderConfiguration
    func loadProfile() -> AIProviderConfiguration { profile }
}

private struct FixedCredentialStore: CredentialStore {
    let value: String?
    func credential(for reference: CredentialReference) -> String? {
        reference == .aiAPIKey ? value : nil
    }
}

final class AIProfileTests: XCTestCase {
    func testProfileKeepsLegacyDecodeDefaults() throws {
        let profile = try JSONDecoder().decode(AIProviderConfiguration.self, from: Data("{}".utf8))

        XCTAssertEqual(profile.name, "My AI")
        XCTAssertEqual(profile.modelSource, .remoteAPI)
        XCTAssertEqual(profile.endpointKind, .openAIResponses)
        XCTAssertEqual(profile.endpointURL, "")
        XCTAssertEqual(profile.model, "")
        XCTAssertEqual(profile.assistantName, "My AI")
    }

    func testProfileUsesExistingCodableKeysAndEnumRawValues() throws {
        var profile = AIProviderConfiguration()
        profile.name = "Reader AI"
        profile.modelSource = .appleOnDevice
        profile.endpointKind = .anthropicMessages
        profile.endpointURL = "https://example.test/messages"
        profile.model = "model-name"

        let encoded = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["name", "modelSource", "endpointKind", "endpointURL", "model"])
        XCTAssertEqual(object["modelSource"] as? String, "appleOnDevice")
        XCTAssertEqual(object["endpointKind"] as? String, "anthropicMessages")
        XCTAssertEqual(try JSONDecoder().decode(AIProviderConfiguration.self, from: encoded), profile)
    }

    func testProfileAndCredentialPortsAreTypedAndIndependent() {
        var profile = AIProviderConfiguration()
        profile.name = "Injected profile"
        let profileSource: AIProfileSource = FixedProfileSource(profile: profile)
        let credentialStore: CredentialStore = FixedCredentialStore(value: "secret-value")

        XCTAssertEqual(profileSource.loadProfile().name, "Injected profile")
        XCTAssertEqual(CredentialReference.aiAPIKey.rawValue, "ai.apiKey")
        XCTAssertEqual(credentialStore.credential(for: .aiAPIKey), "secret-value")
    }
}
