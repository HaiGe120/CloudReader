import CloudReaderCore
import Foundation

struct RemoteAIModel: Decodable, Identifiable, Equatable {
    let id: String
    let displayName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    var title: String {
        guard let displayName, !displayName.isEmpty else { return id }
        return displayName
    }
}

enum AIModelCatalog {
    private struct Page: Decodable {
        let data: [RemoteAIModel]
        let hasMore: Bool?
        let lastID: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }

    static func fetch(profile: AIProviderConfiguration, enteredKey: String) async throws -> [RemoteAIModel] {
        guard let endpoint = AIService.endpoint(for: profile) else { throw AIServiceError.invalidEndpoint }
        let key = try AIProfileStore.requestKey(for: profile, entered: enteredKey)
        let session = URLSession(configuration: .ephemeral, delegate: AIProviderRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await models(endpoint: endpoint, kind: profile.endpointKind, key: key) { request in
            try await session.data(for: request)
        }
    }

    static func models(endpoint: URL, kind: AIEndpointKind, key: String?,
                       send: (URLRequest) async throws -> (Data, URLResponse)) async throws -> [RemoteAIModel] {
        guard var base = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), AIService.origin(of: endpoint) != nil else {
            throw AIServiceError.invalidEndpoint
        }
        let path = "/" + base.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffixes = ["/chat/completions", "/responses", "/messages", "/models"]
        if let suffix = suffixes.first(where: { path.hasSuffix($0) }) {
            base.percentEncodedPath = String(path.dropLast(suffix.count)) + "/models"
        } else if let slash = path.lastIndex(of: "/") {
            base.percentEncodedPath = String(path[..<slash]) + "/models"
        }
        base.fragment = nil
        var modelsByID: [String: RemoteAIModel] = [:]
        var cursors = Set<String>()
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            var pageURL = base
            if kind == .anthropicMessages {
                var query = (base.queryItems ?? []).filter { !["before_id", "after_id", "limit"].contains($0.name) }
                query.append(URLQueryItem(name: "limit", value: "100"))
                if let cursor { query.append(URLQueryItem(name: "after_id", value: cursor)) }
                pageURL.queryItems = query
            }
            guard let url = pageURL.url else { throw AIServiceError.invalidEndpoint }
            var request = AIService.providerRequest(url: url, kind: kind, apiKey: key)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw AIServiceError.unreadableResponse }
            guard (200..<300).contains(http.statusCode) else {
                let message: String
                switch http.statusCode {
                case 401, 403: message = "Check the API key and its permission to list models."
                case 404, 405: message = "This endpoint has no model list. You can enter a model ID in Settings."
                case 429: message = "The provider’s rate limit was reached. Try again shortly."
                default: message = "The provider could not return its model list."
                }
                throw AIServiceError.http(http.statusCode, message)
            }
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else { throw AIServiceError.unreadableResponse }
            for model in page.data where !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                modelsByID[model.id] = model
            }
            cursor = nil
            if kind == .anthropicMessages, page.hasMore == true {
                guard let next = page.lastID, !next.isEmpty, cursors.insert(next).inserted else { throw AIServiceError.unreadableResponse }
                cursor = next
            }
        } while cursor != nil
        return modelsByID.values.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

final class AIProviderRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest, let source = original.url.flatMap(AIService.origin),
              request.url.flatMap(AIService.origin) == source else {
            completionHandler(nil)
            return
        }
        var redirected = request
        for header in ["Authorization", "x-api-key", "anthropic-version"] {
            redirected.setValue(original.value(forHTTPHeaderField: header), forHTTPHeaderField: header)
        }
        completionHandler(redirected)
    }
}
