import Foundation

public enum AIEndpointKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAIChatCompletions
    case openAIResponses
    case anthropicMessages

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAIChatCompletions: "OpenAI · Chat Completions"
        case .openAIResponses: "OpenAI · Responses"
        case .anthropicMessages: "Anthropic · Messages"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .openAIChatCompletions: "https://api.openai.com/v1/chat/completions"
        case .openAIResponses: "https://api.openai.com/v1/responses"
        case .anthropicMessages: "https://api.anthropic.com/v1/messages"
        }
    }

    public var placeholderModel: String {
        switch self {
        case .openAIChatCompletions, .openAIResponses: "gpt-5.2"
        case .anthropicMessages: "claude-sonnet-4-5"
        }
    }
}

public enum AIModelSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case remoteAPI
    case appleOnDevice

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .remoteAPI: "Remote API"
        case .appleOnDevice: "Apple on-device model"
        }
    }
}

public struct AIProviderConfiguration: Codable, Equatable, Sendable {
    public var name = "My AI"
    public var modelSource: AIModelSource = .remoteAPI
    public var endpointKind: AIEndpointKind = .openAIResponses
    public var endpointURL = ""
    public var model = ""

    public var assistantName: String {
        modelSource == .appleOnDevice ? "Apple Intelligence" : name
    }

    private enum CodingKeys: String, CodingKey { case name, modelSource, endpointKind, endpointURL, model }

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "My AI"
        modelSource = try values.decodeIfPresent(AIModelSource.self, forKey: .modelSource) ?? .remoteAPI
        endpointKind = try values.decodeIfPresent(AIEndpointKind.self, forKey: .endpointKind) ?? .openAIResponses
        endpointURL = try values.decodeIfPresent(String.self, forKey: .endpointURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(name, forKey: .name)
        try values.encode(modelSource, forKey: .modelSource)
        try values.encode(endpointKind, forKey: .endpointKind)
        try values.encode(endpointURL, forKey: .endpointURL)
        try values.encode(model, forKey: .model)
    }
}

/// A local credential identifier. It contains a reference, never the credential value.
public enum CredentialReference: String, Hashable, Sendable {
    case aiAPIKey = "ai.apiKey"
}

/// Reads the selected AI profile from an app-owned settings source.
public protocol AIProfileSource {
    func loadProfile() -> AIProviderConfiguration
}

/// Reads secrets through an app-owned secure storage adapter.
public protocol CredentialStore {
    func credential(for reference: CredentialReference) -> String?
}
