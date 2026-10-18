import AuthenticationServices
import CryptoKit
import Citadel
import Foundation
import NIO
import NIOSSH
import Security
import SwiftUI
#if os(macOS)
import AppKit
import Network
#else
import UIKit
#endif

enum CloudProviderKind: String, CaseIterable, Identifiable {
    case googleDrive
    case dropbox
    case pCloud
    case webDAV
    case sftp
    case filesFolder

    var id: String { rawValue }
    var title: String {
        switch self {
        case .googleDrive: "Google Drive"
        case .dropbox: "Dropbox"
        case .pCloud: "pCloud"
        case .webDAV: "WebDAV"
        case .sftp: "SFTP"
        case .filesFolder: "Files folder"
        }
    }
    var symbol: String {
        switch self {
        case .googleDrive: "externaldrive.fill"
        case .dropbox: "shippingbox.fill"
        case .pCloud: "cloud.fill"
        case .webDAV: "server.rack"
        case .sftp: "terminal"
        case .filesFolder: "folder.badge.gearshape"
        }
    }
}

enum CloudSyncError: LocalizedError {
    case notConfigured(String)
    case invalidURL
    case authorization(String)
    case http(Int, String)
    case folderNotSelected
    case malformedResponse
    case service(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let provider): "Set up your \(provider) connection first."
        case .invalidURL: "Enter a valid server URL."
        case .authorization(let reason): "Sign-in failed: \(reason)"
        case .http(let code, let message): "Cloud storage returned HTTP \(code): \(message)"
        case .folderNotSelected: "Choose a folder in Files before syncing."
        case .malformedResponse: "The cloud service returned an unreadable response."
        case .service(let message): message
        }
    }
}

protocol RemoteBookStore {
    func read(_ name: String) async throws -> Data?
    func write(_ data: Data, as name: String) async throws
}

private struct OAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var apiHost: String? = nil
}

struct OAuthClientSecret: Codable {
    var value: String
}

struct OAuthAuthorizationRequest {
    let url: URL
    let redirectURI: String
    let callbackScheme: String
}

enum SecureVault {
    static func save<T: Encodable>(_ value: T, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.github.haige120.cloudreader", kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        #if os(iOS)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudSyncError.authorization("Keychain save failed (\(status)).") }
    }

    static func load<T: Decodable>(_ type: T.Type, account: String) -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.github.haige120.cloudreader", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func remove(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.github.haige120.cloudreader", kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
private final class OAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authorize(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let error { continuation.resume(throwing: error); return }
                guard let callback else { continuation.resume(throwing: CloudSyncError.authorization("No callback was received.")); return }
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                continuation.resume(throwing: CloudSyncError.authorization("The sign-in window could not be opened."))
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else {
            preconditionFailure("OAuth presentation requires an active app window.")
        }
        return window
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return keyWindow }
        guard let scene = scenes.first else { preconditionFailure("OAuth presentation requires an active window scene.") }
        return UIWindow(windowScene: scene)
        #endif
    }
}

@MainActor
enum OAuthConnector {
    static func connect(_ kind: CloudProviderKind, clientID: String, clientSecret: String? = nil) async throws {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw CloudSyncError.notConfigured("an OAuth app ID") }
        let clientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = randomString(count: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = UUID().uuidString
        let request: OAuthAuthorizationRequest
        let callback: URL
        #if os(macOS)
        if kind == .googleDrive {
            let receiver = GoogleLoopbackReceiver()
            let redirectURI = try await receiver.start()
            do {
                request = try googleDesktopAuthorizationRequest(
                    clientID: clientID,
                    state: state,
                    challenge: challenge,
                    redirectURI: redirectURI
                )
            } catch {
                receiver.cancel()
                throw error
            }
            guard NSWorkspace.shared.open(request.url) else {
                receiver.cancel()
                throw CloudSyncError.authorization("The default browser could not be opened.")
            }
            callback = try await receiver.waitForCallback()
        } else {
            request = try authorizationRequest(kind: kind, clientID: clientID, state: state, challenge: challenge)
            callback = try await OAuthBrowser().authorize(url: request.url, callbackScheme: request.callbackScheme)
        }
        #else
        request = try authorizationRequest(kind: kind, clientID: clientID, state: state, challenge: challenge)
        callback = try await OAuthBrowser().authorize(url: request.url, callbackScheme: request.callbackScheme)
        #endif
        let values = callbackValues(callback, includeFragment: kind == .pCloud || kind == .googleDrive)
        guard values.first(where: { $0.name == "state" })?.value == state else { throw CloudSyncError.authorization("The returned state did not match the sign-in request.") }

        if let providerError = values.first(where: { $0.name == "error" })?.value {
            let detail = values.first(where: { $0.name == "error_description" })?.value
            throw CloudSyncError.authorization(detail ?? providerError)
        }

        if kind == .pCloud {
            guard let accessToken = values.first(where: { $0.name == "access_token" })?.value,
                  let apiHost = values.first(where: { $0.name == "hostname" })?.value,
                  ["api.pcloud.com", "eapi.pcloud.com"].contains(apiHost) else {
                throw CloudSyncError.authorization("pCloud did not return a valid access token and regional API host.")
            }
            try SecureVault.save(OAuthToken(accessToken: accessToken, refreshToken: nil, expiresAt: .distantFuture, apiHost: apiHost), account: kind.rawValue + ".oauth")
            return
        }

        guard let code = values.first(where: { $0.name == "code" })?.value else {
            throw CloudSyncError.authorization("No authorization code was returned. Check the provider's registered redirect URI and try again.")
        }
        let token = try await exchange(code: code, verifier: verifier, clientID: clientID, clientSecret: clientSecret, redirectURI: request.redirectURI, kind: kind)
        try SecureVault.save(token, account: kind.rawValue + ".oauth")
    }

    static func authorizationRequest(kind: CloudProviderKind, clientID: String, state: String, challenge: String) throws -> OAuthAuthorizationRequest {
        let redirectURI: String
        let callbackScheme: String
        let endpoint: String
        var items = [URLQueryItem(name: "client_id", value: clientID)]

        switch kind {
        case .googleDrive:
            let labels = clientID.split(separator: ".").map(String.init)
            guard labels.count >= 4, labels.suffix(3).map({ $0.lowercased() }) == ["apps", "googleusercontent", "com"] else {
                throw CloudSyncError.authorization("Use a Google OAuth client ID ending in .apps.googleusercontent.com from Google Cloud Console.")
            }
            callbackScheme = labels.reversed().joined(separator: ".")
            redirectURI = "\(callbackScheme):/oauth2redirect"
            endpoint = "https://accounts.google.com/o/oauth2/v2/auth"
            items += [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.appdata"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "state", value: state)
            ]
        case .dropbox:
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard !clientID.isEmpty, clientID.unicodeScalars.allSatisfy(allowed.contains) else {
                throw CloudSyncError.authorization("The Dropbox app key contains unsupported characters.")
            }
            callbackScheme = "db-\(clientID)"
            redirectURI = "\(callbackScheme)://2/token"
            endpoint = "https://www.dropbox.com/oauth2/authorize"
            items += [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "token_access_type", value: "offline"),
                URLQueryItem(name: "scope", value: "files.content.read files.content.write files.metadata.read files.metadata.write"),
                URLQueryItem(name: "state", value: state)
            ]
        case .pCloud:
            callbackScheme = "cloudreader"
            redirectURI = "cloudreader://pcloud-oauth"
            endpoint = "https://my.pcloud.com/oauth2/authorize"
            items += [
                URLQueryItem(name: "response_type", value: "token"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "state", value: state)
            ]
        default:
            throw CloudSyncError.notConfigured(kind.title)
        }

        var components = URLComponents(string: endpoint)!
        components.queryItems = items
        guard let url = components.url else { throw CloudSyncError.invalidURL }
        return OAuthAuthorizationRequest(url: url, redirectURI: redirectURI, callbackScheme: callbackScheme)
    }

    #if os(macOS)
    private static func googleDesktopAuthorizationRequest(
        clientID: String,
        state: String,
        challenge: String,
        redirectURI: String
    ) throws -> OAuthAuthorizationRequest {
        let labels = clientID.split(separator: ".").map(String.init)
        guard labels.count >= 4, labels.suffix(3).map({ $0.lowercased() }) == ["apps", "googleusercontent", "com"] else {
            throw CloudSyncError.authorization("Use a Google OAuth client ID for a Desktop app, ending in .apps.googleusercontent.com.")
        }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.appdata"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components.url else { throw CloudSyncError.invalidURL }
        return OAuthAuthorizationRequest(url: url, redirectURI: redirectURI, callbackScheme: "")
    }
    #endif

    private static func callbackValues(_ url: URL, includeFragment: Bool) -> [URLQueryItem] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var values = components?.queryItems ?? []
        if includeFragment, let fragment = components?.fragment, !fragment.isEmpty,
           let fragmentItems = URLComponents(string: "https://callback.invalid/?\(fragment)")?.queryItems {
            values.append(contentsOf: fragmentItems)
        }
        return values
    }

    static func accessToken(for kind: CloudProviderKind) async throws -> String {
        guard let token = SecureVault.load(OAuthToken.self, account: kind.rawValue + ".oauth") else { throw CloudSyncError.notConfigured(kind.title) }
        if token.expiresAt > Date().addingTimeInterval(90) { return token.accessToken }
        guard let refresh = token.refreshToken, let clientID = UserDefaults.standard.string(forKey: kind.rawValue + ".clientID") else {
            throw CloudSyncError.authorization("Sign in again to refresh this connection.")
        }
        let clientSecret = kind == .googleDrive ? SecureVault.load(OAuthClientSecret.self, account: kind.rawValue + ".clientSecret")?.value : nil
        let refreshed = try await refreshToken(refresh, clientID: clientID, clientSecret: clientSecret, kind: kind)
        try SecureVault.save(refreshed, account: kind.rawValue + ".oauth")
        return refreshed.accessToken
    }

    static func pCloudAPIHost() throws -> String {
        guard let token = SecureVault.load(OAuthToken.self, account: CloudProviderKind.pCloud.rawValue + ".oauth"),
              let host = token.apiHost,
              ["api.pcloud.com", "eapi.pcloud.com"].contains(host) else {
            throw CloudSyncError.notConfigured("pCloud")
        }
        return host
    }

    private static func exchange(code: String, verifier: String, clientID: String, clientSecret: String?, redirectURI: String, kind: CloudProviderKind) async throws -> OAuthToken {
        var request = URLRequest(url: URL(string: kind == .googleDrive ? "https://oauth2.googleapis.com/token" : "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = [
            "code": code, "client_id": clientID, "redirect_uri": redirectURI,
            "grant_type": "authorization_code", "code_verifier": verifier
        ]
        if kind == .googleDrive, let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        request.httpBody = formData(fields)
        return try await decodeToken(request)
    }

    private static func refreshToken(_ refresh: String, clientID: String, clientSecret: String?, kind: CloudProviderKind) async throws -> OAuthToken {
        var request = URLRequest(url: URL(string: kind == .googleDrive ? "https://oauth2.googleapis.com/token" : "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = ["refresh_token": refresh, "client_id": clientID, "grant_type": "refresh_token"]
        if kind == .googleDrive, let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        request.httpBody = formData(fields)
        var refreshed = try await decodeToken(request)
        refreshed.refreshToken = refresh
        return refreshed
    }

    private static func decodeToken(_ request: URLRequest) async throws -> OAuthToken {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            throw CloudSyncError.authorization(body?.errorDescription ?? body?.error ?? String(data: data, encoding: .utf8)?.prefix(400).description ?? "The token endpoint rejected the request.")
        }
        let raw = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthToken(accessToken: raw.accessToken, refreshToken: raw.refreshToken, expiresAt: Date().addingTimeInterval(TimeInterval(raw.expiresIn ?? 3600)))
    }

    private struct TokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Int?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
    }

    private struct TokenErrorResponse: Decodable {
        var error: String?
        var errorDescription: String?
        enum CodingKeys: String, CodingKey { case error, errorDescription = "error_description" }
    }

    private static func randomString(count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            let fallback = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            return String(fallback.prefix(count))
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func formData(_ fields: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

#if os(macOS)
@MainActor
private final class GoogleLoopbackReceiver {
    private var listener: NWListener?
    private var startContinuation: CheckedContinuation<String, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var receivedCallback: URL?
    private var timeoutTask: Task<Void, Never>?

    func start() async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener?.port else {
                        self.fail(CloudSyncError.authorization("Could not reserve a local sign-in callback port."))
                        return
                    }
                    self.startContinuation?.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                    self.startContinuation = nil
                    self.timeoutTask = Task { @MainActor [weak self] in
                        do { try await Task.sleep(nanoseconds: 300_000_000_000) }
                        catch { return }
                        self?.fail(CloudSyncError.authorization("Google sign-in timed out. Start Connect again to retry."))
                    }
                case .failed(let error):
                    self.fail(CloudSyncError.authorization("Could not start the local sign-in callback: \(error.localizedDescription)"))
                case .waiting(let error):
                    self.fail(CloudSyncError.authorization("The local sign-in callback is waiting for network access: \(error.localizedDescription)"))
                case .cancelled:
                    self.fail(CloudSyncError.authorization("Google sign-in was cancelled."))
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection) }
        }
        listener.start(queue: .main)
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    func waitForCallback() async throws -> URL {
        if let receivedCallback { return receivedCallback }
        return try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            let bytes = accumulated + (data ?? Data())
            let terminator = Data("\r\n\r\n".utf8)
            if let headerEnd = bytes.range(of: terminator) {
                let header = String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self)
                let requestLine = header.components(separatedBy: "\r\n").first ?? ""
                let pieces = requestLine.split(separator: " ")
                if pieces.count >= 2,
                   pieces[0] == "GET",
                   let callback = URL(string: "http://127.0.0.1\(pieces[1])") {
                    guard let receiver = self else {
                        connection.cancel()
                        return
                    }
                    let body = "Google sign-in is complete. You can return to CloudReader."
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                        Task { @MainActor in receiver.complete(callback) }
                    })
                } else {
                    connection.cancel()
                }
            } else if let error {
                connection.cancel()
                Task { @MainActor in
                    self?.fail(CloudSyncError.authorization("Could not read Google’s sign-in response: \(error.localizedDescription)"))
                }
            } else if isComplete || bytes.count > 32_768 {
                connection.cancel()
            } else {
                Task { @MainActor in self?.receiveRequest(on: connection, accumulated: bytes) }
            }
        }
    }

    private func complete(_ callback: URL) {
        receivedCallback = callback
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        callbackContinuation?.resume(returning: callback)
        callbackContinuation = nil
    }

    private func fail(_ error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        startContinuation?.resume(throwing: error)
        startContinuation = nil
        callbackContinuation?.resume(throwing: error)
        callbackContinuation = nil
    }
}
#endif

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum RemoteStoreFactory {
    static func make(_ kind: CloudProviderKind) throws -> any RemoteBookStore {
        switch kind {
        case .googleDrive: GoogleDriveStore()
        case .dropbox: DropboxStore()
        case .pCloud: PCloudStore()
        case .webDAV: try WebDAVStore.fromSavedSettings()
        case .sftp: try SFTPStore.fromSavedSettings()
        case .filesFolder: FilesFolderStore()
        }
    }
}

private struct GoogleDriveStore: RemoteBookStore {
    private struct FileList: Decodable { var files: [DriveFile] }
    private struct DriveFile: Decodable { var id: String; var name: String }

    func read(_ name: String) async throws -> Data? {
        guard let id = try await findFile(name) else { return nil }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        request.setValue("Bearer \(try await googleAccessToken())", forHTTPHeaderField: "Authorization")
        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw CloudSyncError.service("Google Drive download request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw CloudSyncError.malformedResponse }
        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        guard (200..<300).contains(http.statusCode) else {
            throw CloudSyncError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func write(_ data: Data, as name: String) async throws {
        let token = try await googleAccessToken()
        let existingID: String?
        do {
            existingID = try await findFile(name)
        } catch {
            throw CloudSyncError.service("Google Drive file lookup failed: \(error.localizedDescription)")
        }
        // Drive's simple and multipart upload modes are limited to 5 MB. Books
        // commonly exceed that, so use Drive's resumable upload protocol for
        // larger content instead of sending the entire book in one request.
        if data.count > 5 * 1_024 * 1_024 {
            try await writeResumably(data, as: name, existingID: existingID, token: token)
            return
        }

        var request: URLRequest
        if let existingID {
            var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files/\(existingID)")!
            components.queryItems = [URLQueryItem(name: "uploadType", value: "media")]
            request = URLRequest(url: components.url!)
            request.httpMethod = "PATCH"
            request.httpBody = data
        } else {
            var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
            components.queryItems = [URLQueryItem(name: "uploadType", value: "multipart"), URLQueryItem(name: "fields", value: "id")]
            request = URLRequest(url: components.url!)
            let boundary = "CloudReader-\(UUID().uuidString)"
            request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": ["appDataFolder"]])
            var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
            body.append(metadata)
            body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--".utf8))
            request.httpBody = body
        }
        // URLRequest defaults to GET, so always set the upload verb explicitly.
        request.httpMethod = existingID == nil ? "POST" : "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if existingID != nil { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        do {
            _ = try await responseData(request)
        } catch {
            let action = existingID == nil ? "create" : "replace"
            throw CloudSyncError.service("Google Drive \(action) upload failed: \(networkErrorSummary(error))")
        }
    }

    private func writeResumably(_ data: Data, as name: String, existingID: String?, token: String) async throws {
        let endpoint = existingID.map { "https://www.googleapis.com/upload/drive/v3/files/\($0)" }
            ?? "https://www.googleapis.com/upload/drive/v3/files"
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: "id")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = existingID == nil ? "POST" : "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
        if existingID == nil {
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "name": name,
                "parents": ["appDataFolder"]
            ])
        }

        let initiationData: Data
        let initiationResponse: HTTPURLResponse
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudSyncError.malformedResponse }
            initiationData = data
            initiationResponse = http
        } catch {
            throw CloudSyncError.service("Google Drive upload session request failed: \(networkErrorSummary(error))")
        }
        guard (200..<300).contains(initiationResponse.statusCode) else {
            throw CloudSyncError.http(initiationResponse.statusCode, String(data: initiationData, encoding: .utf8) ?? "")
        }
        guard let location = initiationResponse.value(forHTTPHeaderField: "Location"),
              let sessionURL = URL(string: location, relativeTo: initiationResponse.url)?.absoluteURL else {
            throw CloudSyncError.service("Google Drive did not return an upload session. Please try again.")
        }

        let chunkSize = 1 * 1_024 * 1_024 // Matches Google's documented resumable-upload example.
        var offset = 0
        var stalledChunks = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            var chunkRequest = URLRequest(url: sessionURL)
            chunkRequest.httpMethod = "PUT"
            chunkRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            chunkRequest.setValue(String(end - offset), forHTTPHeaderField: "Content-Length")
            chunkRequest.setValue("bytes \(offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
            chunkRequest.httpBody = data.subdata(in: offset..<end)

            let chunkData: Data
            let chunkHTTP: HTTPURLResponse
            do {
                let (data, response) = try await URLSession.shared.data(for: chunkRequest)
                guard let http = response as? HTTPURLResponse else { throw CloudSyncError.malformedResponse }
                chunkData = data
                chunkHTTP = http
            } catch {
                throw CloudSyncError.service("Google Drive upload data request failed: \(networkErrorSummary(error))")
            }
            if chunkHTTP.statusCode == 200 || chunkHTTP.statusCode == 201 { return }
            guard chunkHTTP.statusCode == 308 else {
                throw CloudSyncError.http(chunkHTTP.statusCode, String(data: chunkData, encoding: .utf8) ?? "")
            }

            let acceptedOffset = chunkHTTP.value(forHTTPHeaderField: "Range")
                .flatMap(Self.uploadedByteOffset(from:)) ?? 0
            guard acceptedOffset > offset else {
                stalledChunks += 1
                guard stalledChunks < 3 else {
                    throw CloudSyncError.service("Google Drive accepted no upload data. Please try syncing again.")
                }
                continue
            }
            guard acceptedOffset < data.count else {
                throw CloudSyncError.service("Google Drive received all book data but did not finish the upload. Please try syncing again.")
            }
            stalledChunks = 0
            offset = acceptedOffset
        }
    }

    private static func uploadedByteOffset(from range: String) -> Int? {
        guard let lastByte = Int(range.split(separator: "-").last ?? "") else { return nil }
        return lastByte + 1
    }

    private func googleAccessToken() async throws -> String {
        do {
            return try await OAuthConnector.accessToken(for: .googleDrive)
        } catch {
            throw CloudSyncError.service("Google Drive sign-in request failed: \(error.localizedDescription)")
        }
    }

    private func findFile(_ name: String) async throws -> String? {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "'appDataFolder' in parents and name='\(name)' and trashed=false"),
            URLQueryItem(name: "fields", value: "files(id,name)"), URLQueryItem(name: "pageSize", value: "10")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await googleAccessToken())", forHTTPHeaderField: "Authorization")
        let data: Data
        do {
            data = try await responseData(request)
        } catch {
            throw CloudSyncError.service("Google Drive file search failed: \(error.localizedDescription)")
        }
        return try JSONDecoder().decode(FileList.self, from: data).files.first?.id
    }
}

private struct DropboxStore: RemoteBookStore {
    func read(_ name: String) async throws -> Data? {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await OAuthConnector.accessToken(for: .dropbox))", forHTTPHeaderField: "Authorization")
        request.setValue(try argument(path: name), forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudSyncError.malformedResponse }
        if http.statusCode == 409, dropboxErrorSummary(data)?.hasPrefix("path/not_found/") == true { return nil }
        guard (200..<300).contains(http.statusCode) else { throw CloudSyncError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    func write(_ data: Data, as name: String) async throws {
        let path = "/CloudReader/\(name)"
        try await createFolderIfNeeded()
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await OAuthConnector.accessToken(for: .dropbox))", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data: try JSONSerialization.data(withJSONObject: ["path": path, "mode": "overwrite", "autorename": false, "mute": true]), encoding: .utf8), forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = data
        _ = try await responseData(request)
    }

    private func createFolderIfNeeded() async throws {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/create_folder_v2")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await OAuthConnector.accessToken(for: .dropbox))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": "/CloudReader", "autorename": false])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudSyncError.malformedResponse }
        if (200..<300).contains(http.statusCode) { return }
        if http.statusCode == 409, dropboxErrorSummary(data)?.hasPrefix("path/conflict/folder") == true { return }
        throw CloudSyncError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    private func argument(path: String) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: ["path": "/CloudReader/\(path)"])
        return String(data: json, encoding: .utf8)!
    }

    private func dropboxErrorSummary(_ data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return body["error_summary"] as? String
    }
}

private actor PCloudStore: RemoteBookStore {
    private struct FolderMetadata: Decodable {
        var folderID: Int?
        var contents: [Entry]?
        enum CodingKeys: String, CodingKey { case folderID = "folderid", contents }
    }

    private struct Entry: Decodable {
        var name: String
        var isFolder: Bool
        var folderID: Int?
        var fileID: Int?
        enum CodingKeys: String, CodingKey {
            case name, isFolder = "isfolder", folderID = "folderid", fileID = "fileid"
        }
    }

    private struct Envelope<Value: Decodable>: Decodable {
        var result: Int
        var error: String?
        var metadata: Value?
        var hosts: [String]?
        var path: String?
    }

    private struct ResultResponse: Decodable {
        var result: Int
        var error: String?
    }

    private var cachedFolderID: Int?
    private var cachedEntries: [Entry]?

    func read(_ name: String) async throws -> Data? {
        _ = try await ensureCloudReaderFolder()
        let entries = try await cloudReaderEntries()
        guard let entry = entries.first(where: { !$0.isFolder && $0.name == name }), let fileID = entry.fileID else { return nil }
        let link: Envelope<FolderMetadata> = try await api("getfilelink", parameters: [URLQueryItem(name: "fileid", value: String(fileID))])
        guard let host = link.hosts?.first, host.hasSuffix(".pcloud.com"),
              let path = link.path, path.hasPrefix("/"),
              let url = URL(string: "https://\(host)\(path)") else { throw CloudSyncError.malformedResponse }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudSyncError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "Unable to download the pCloud file.")
        }
        return data
    }

    func write(_ data: Data, as name: String) async throws {
        let folderID = try await ensureCloudReaderFolder()
        let boundary = "CloudReader-\(UUID().uuidString)"
        var body = Data()
        appendField("folderid", value: String(folderID), boundary: boundary, to: &body)
        appendField("nopartial", value: "1", boundary: boundary, to: &body)
        let safeName = name.replacingOccurrences(of: "\"", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: try await apiURL("uploadfile"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await OAuthConnector.accessToken(for: .pCloud))", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let data = try await responseData(request)
        let response = try JSONDecoder().decode(ResultResponse.self, from: data)
        guard response.result == 0 else { throw providerError(response.result, response.error) }
        cachedEntries = nil
    }

    private func ensureCloudReaderFolder() async throws -> Int {
        if let cachedFolderID { return cachedFolderID }
        if let existing = (try await folderContents(folderID: 0)).first(where: { $0.isFolder && $0.name == "CloudReader" }), let folderID = existing.folderID {
            cachedFolderID = folderID
            return folderID
        }

        let createURL = try await apiURL("createfolder", parameters: [
            URLQueryItem(name: "folderid", value: "0"),
            URLQueryItem(name: "name", value: "CloudReader")
        ])
        var request = URLRequest(url: createURL)
        request.setValue("Bearer \(try await OAuthConnector.accessToken(for: .pCloud))", forHTTPHeaderField: "Authorization")
        let response: Envelope<Entry> = try await decodeEnvelope(request)
        if response.result == 0, let folderID = response.metadata?.folderID {
            cachedFolderID = folderID
            return folderID
        }
        if response.result == 2004,
           let existing = (try await folderContents(folderID: 0)).first(where: { $0.isFolder && $0.name == "CloudReader" }),
           let folderID = existing.folderID {
            cachedFolderID = folderID
            return folderID
        }
        throw providerError(response.result, response.error)
    }

    private func cloudReaderEntries() async throws -> [Entry] {
        if let cachedEntries { return cachedEntries }
        let folderID = try await ensureCloudReaderFolder()
        let entries = try await folderContents(folderID: folderID)
        cachedEntries = entries
        return entries
    }

    private func folderContents(folderID: Int) async throws -> [Entry] {
        let response: Envelope<FolderMetadata> = try await api("listfolder", parameters: [URLQueryItem(name: "folderid", value: String(folderID))])
        guard response.result == 0 else { throw providerError(response.result, response.error) }
        return response.metadata?.contents ?? []
    }

    private func api<Value: Decodable>(_ method: String, parameters: [URLQueryItem] = []) async throws -> Envelope<Value> {
        var request = URLRequest(url: try await apiURL(method, parameters: parameters))
        request.setValue("Bearer \(try await OAuthConnector.accessToken(for: .pCloud))", forHTTPHeaderField: "Authorization")
        return try await decodeEnvelope(request)
    }

    private func apiURL(_ method: String, parameters: [URLQueryItem] = []) async throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = try await OAuthConnector.pCloudAPIHost()
        components.path = "/\(method)"
        components.queryItems = parameters.isEmpty ? nil : parameters
        guard let url = components.url else { throw CloudSyncError.invalidURL }
        return url
    }

    private func decodeEnvelope<Value: Decodable>(_ request: URLRequest) async throws -> Envelope<Value> {
        let data = try await responseData(request)
        guard let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data) else { throw CloudSyncError.malformedResponse }
        return envelope
    }

    private func providerError(_ code: Int, _ message: String?) -> CloudSyncError {
        .service("pCloud returned error \(code)\(message.map { ": \($0)" } ?? ".")")
    }

    private func appendField(_ name: String, value: String, boundary: String, to data: inout Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
}

private struct WebDAVStore: RemoteBookStore {
    private let baseURL: URL
    private let username: String
    private let password: String

    static func fromSavedSettings() throws -> WebDAVStore {
        guard let raw = UserDefaults.standard.string(forKey: "webdav.url"), let url = URL(string: raw),
              let credentials = SecureVault.load(WebDAVCredentials.self, account: "webdav") else { throw CloudSyncError.notConfigured("WebDAV") }
        return WebDAVStore(baseURL: url, username: credentials.username, password: credentials.password)
    }

    func read(_ name: String) async throws -> Data? {
        var request = makeRequest(name)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudSyncError.malformedResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw CloudSyncError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    func write(_ data: Data, as name: String) async throws {
        var collection = URLRequest(url: baseURL.appendingPathComponent("CloudReader", isDirectory: true))
        collection.httpMethod = "MKCOL"
        authorize(&collection)
        let (collectionData, collectionResponse) = try await URLSession.shared.data(for: collection)
        if let http = collectionResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) && http.statusCode != 405 && http.statusCode != 301 {
            throw CloudSyncError.http(http.statusCode, webDAVFailure("MKCOL", status: http.statusCode, response: collectionData))
        }
        var request = makeRequest(name)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CloudSyncError.http(status, webDAVFailure("PUT upload", status: status, response: responseData))
        }
    }

    private func makeRequest(_ name: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("CloudReader", isDirectory: true).appendingPathComponent(name))
        authorize(&request)
        return request
    }

    private func authorize(_ request: inout URLRequest) {
        let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }

    private func webDAVFailure(_ operation: String, status: Int, response: Data) -> String {
        let serverMessage = String(data: response, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let serverMessage, !serverMessage.isEmpty {
            return "WebDAV \(operation) failed (HTTP \(status)): \(serverMessage.prefix(500))"
        }
        return "WebDAV \(operation) was denied (HTTP \(status)). Check that the server URL points to its WebDAV folder and this account can create folders and upload files."
    }
}

struct WebDAVCredentials: Codable {
    var username: String
    var password: String
}

struct SFTPServerCredentials: Codable {
    var host: String
    var port: Int
    var username: String
    var password: String
    var directory: String
    var pinnedHostKey: String
}

private actor SFTPStore: RemoteBookStore {
    private let credentials: SFTPServerCredentials
    private var sshClient: SSHClient?
    private var sftpClient: SFTPClient?

    static func fromSavedSettings() throws -> SFTPStore {
        guard let credentials = SecureVault.load(SFTPServerCredentials.self, account: "sftp") else { throw CloudSyncError.notConfigured("SFTP") }
        return SFTPStore(credentials: credentials)
    }

    private init(credentials: SFTPServerCredentials) { self.credentials = credentials }

    func read(_ name: String) async throws -> Data? {
        let sftp = try await connection()
        do {
            let buffer = try await sftp.withFile(filePath: path(name), flags: .read) { file in try await file.readAll() }
            return buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) ?? Data()
        } catch SFTPError.errorStatus(let status) where status.errorCode == .noSuchFile {
            return nil
        } catch {
            await closeConnection()
            throw error
        }
    }

    func write(_ data: Data, as name: String) async throws {
        let sftp = try await connection()
        do {
            try? await sftp.createDirectory(atPath: credentials.directory)
            try await sftp.withFile(filePath: path(name), flags: [.write, .create, .truncate]) { file in
                try await file.write(ByteBuffer(bytes: data))
            }
        } catch {
            await closeConnection()
            throw error
        }
    }

    func closeConnection() async {
        if let sftpClient { try? await sftpClient.close() }
        if let sshClient { try? await sshClient.close() }
        sftpClient = nil
        sshClient = nil
    }

    private func path(_ name: String) -> String {
        let value = credentials.directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !value.isEmpty else { return name }
        let root = credentials.directory.hasPrefix("/") ? "/\(value)" : value
        return "\(root)/\(name)"
    }

    private func connection() async throws -> SFTPClient {
        if let sftpClient { return sftpClient }
        let hostKey = try NIOSSHPublicKey(openSSHPublicKey: credentials.pinnedHostKey)
        let username = credentials.username
        let password = credentials.password
        let settings = SSHClientSettings(
            host: credentials.host,
            port: credentials.port,
            authenticationMethod: { .passwordBased(username: username, password: password) },
            hostKeyValidator: .trustedKeys([hostKey])
        )
        let ssh = try await SSHClient.connect(to: settings)
        do {
            let client = try await ssh.openSFTP()
            sshClient = ssh
            sftpClient = client
            return client
        } catch {
            try? await ssh.close()
            throw error
        }
    }
}

struct FilesFolderStore: RemoteBookStore {
    private let key = "cloudreader.syncFolderBookmark"

    func read(_ name: String) async throws -> Data? {
        try withFolder { root in
            let file = root.appendingPathComponent("CloudReader", isDirectory: true).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            var result: Data?
            var coordinationError: NSError?
            var readError: Error?
            NSFileCoordinator().coordinate(readingItemAt: file, options: .withoutChanges, error: &coordinationError) { url in
                do { result = try Data(contentsOf: url) } catch { readError = error }
            }
            if let coordinationError { throw coordinationError }
            if let readError { throw readError }
            return result
        }
    }

    func write(_ data: Data, as name: String) async throws {
        try withFolder { root in
            let directory = root.appendingPathComponent("CloudReader", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(name)
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }
    }

    static func saveFolderBookmark(_ url: URL) throws {
        #if os(macOS)
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        UserDefaults.standard.set(bookmark, forKey: "cloudreader.syncFolderBookmark")
    }

    private func withFolder<T>(_ operation: (URL) throws -> T) throws -> T {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else { throw CloudSyncError.folderNotSelected }
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        if stale { try Self.saveFolderBookmark(url) }
        return try operation(url)
    }
}

private func responseData(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw CloudSyncError.malformedResponse }
    guard (200..<300).contains(http.statusCode) else {
        throw CloudSyncError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
    return data
}

private func networkErrorSummary(_ error: Error) -> String {
    let value = error as NSError
    return "\(error.localizedDescription) (\(value.domain) \(value.code))"
}

struct SyncedBook: Codable {
    var book: Book
    var sha256: String
}

struct RemoteLibraryManifest: Codable {
    var schemaVersion = 1
    var updatedAt = Date()
    var books: [SyncedBook] = []
    var deletions: [BookDeletion] = []
    var conversations: [AIConversationRecord] = []
    var conversationDeletions: [AIConversationDeletion] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAt, books, deletions, conversations, conversationDeletions
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        books = try values.decodeIfPresent([SyncedBook].self, forKey: .books) ?? []
        deletions = try values.decodeIfPresent([BookDeletion].self, forKey: .deletions) ?? []
        conversations = try values.decodeIfPresent([AIConversationRecord].self, forKey: .conversations) ?? []
        conversationDeletions = try values.decodeIfPresent([AIConversationDeletion].self, forKey: .conversationDeletions) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(books, forKey: .books)
        try values.encode(deletions, forKey: .deletions)
        try values.encode(conversations, forKey: .conversations)
        try values.encode(conversationDeletions, forKey: .conversationDeletions)
    }
}

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage = "Not connected"
    @Published private(set) var selectedDestinationsVersion = 0
    private var syncAgainRequested = false

    private let selectedProvidersKey = "cloudreader.providers"

    var selectedProviders: [CloudProviderKind] {
        get {
            if let stored = UserDefaults.standard.stringArray(forKey: selectedProvidersKey) {
                return uniqueProviders(stored.compactMap(CloudProviderKind.init(rawValue:)))
            }
            // Migrate the previous single sync-home choice without losing its connection.
            if let legacy = UserDefaults.standard.string(forKey: "cloudreader.provider"),
               let provider = CloudProviderKind(rawValue: legacy), isConnected(provider) {
                return [provider]
            }
            return []
        }
        set {
            let normalized = uniqueProviders(newValue)
            UserDefaults.standard.set(normalized.map(\.rawValue), forKey: selectedProvidersKey)
            if let first = normalized.first {
                UserDefaults.standard.set(first.rawValue, forKey: "cloudreader.provider")
            }
            selectedDestinationsVersion += 1
        }
    }

    var connectedSelectedProviders: [CloudProviderKind] {
        selectedProviders.filter(isConnected)
    }

    var canSync: Bool { !connectedSelectedProviders.isEmpty }

    func isSelected(_ kind: CloudProviderKind) -> Bool {
        selectedProviders.contains(kind)
    }

    func setSelected(_ kind: CloudProviderKind, selected: Bool) {
        var providers = selectedProviders
        if selected {
            guard isConnected(kind), !providers.contains(kind) else { return }
            providers.append(kind)
        } else {
            providers.removeAll { $0 == kind }
        }
        selectedProviders = providers
    }

    private func uniqueProviders(_ providers: [CloudProviderKind]) -> [CloudProviderKind] {
        var seen = Set<CloudProviderKind>()
        return providers.filter { seen.insert($0).inserted }
    }

    func isConnected(_ kind: CloudProviderKind) -> Bool {
        switch kind {
        case .googleDrive, .dropbox, .pCloud: SecureVault.load(OAuthToken.self, account: kind.rawValue + ".oauth") != nil
        case .webDAV: UserDefaults.standard.bool(forKey: "webdav.verified") && SecureVault.load(WebDAVCredentials.self, account: "webdav") != nil && UserDefaults.standard.string(forKey: "webdav.url") != nil
        case .sftp: UserDefaults.standard.bool(forKey: "sftp.verified") && SecureVault.load(SFTPServerCredentials.self, account: "sftp") != nil
        case .filesFolder: UserDefaults.standard.data(forKey: "cloudreader.syncFolderBookmark") != nil
        }
    }

    func connectOAuth(_ kind: CloudProviderKind, clientID: String) async -> Bool {
        await connectOAuth(kind, clientID: clientID, clientSecret: nil)
    }

    func connectOAuth(_ kind: CloudProviderKind, clientID: String, clientSecret: String?) async -> Bool {
        errorMessage = nil
        do {
            let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedClientID.isEmpty else { throw CloudSyncError.notConfigured("OAuth app ID") }
            let normalizedClientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
            if kind == .googleDrive {
                if let normalizedClientSecret, !normalizedClientSecret.isEmpty {
                    try SecureVault.save(OAuthClientSecret(value: normalizedClientSecret), account: kind.rawValue + ".clientSecret")
                } else {
                    SecureVault.remove(account: kind.rawValue + ".clientSecret")
                }
            }
            try await OAuthConnector.connect(kind, clientID: normalizedClientID, clientSecret: normalizedClientSecret)
            UserDefaults.standard.set(normalizedClientID, forKey: kind.rawValue + ".clientID")
            setSelected(kind, selected: true)
            statusMessage = "Connected to \(kind.title)"
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func connectWebDAV(url: String, username: String, password: String) async {
        var credentialsSaved = false
        do {
            guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https", parsed.host != nil else { throw CloudSyncError.invalidURL }
            try SecureVault.save(WebDAVCredentials(username: username, password: password), account: "webdav")
            credentialsSaved = true
            UserDefaults.standard.set(parsed.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forKey: "webdav.url")
            UserDefaults.standard.set(false, forKey: "webdav.verified")
            let store = try WebDAVStore.fromSavedSettings()
            _ = try await store.read("manifest.json")
            UserDefaults.standard.set(true, forKey: "webdav.verified")
            setSelected(.webDAV, selected: true)
            statusMessage = "Connected to WebDAV"
            errorMessage = nil
        } catch {
            if credentialsSaved { SecureVault.remove(account: "webdav") }
            UserDefaults.standard.set(false, forKey: "webdav.verified")
            errorMessage = error.localizedDescription
        }
    }

    func connectSFTP(host: String, port: String, username: String, password: String, directory: String, pinnedHostKey: String) async {
        var credentialsSaved = false
        do {
            guard let numericPort = Int(port), (1...65535).contains(numericPort), !host.isEmpty, !username.isEmpty, !password.isEmpty else { throw CloudSyncError.notConfigured("complete SFTP server details") }
            _ = try NIOSSHPublicKey(openSSHPublicKey: pinnedHostKey)
            let credentials = SFTPServerCredentials(host: host, port: numericPort, username: username, password: password, directory: directory.isEmpty ? "CloudReader" : directory, pinnedHostKey: pinnedHostKey)
            try SecureVault.save(credentials, account: "sftp")
            credentialsSaved = true
            UserDefaults.standard.set(false, forKey: "sftp.verified")
            let store = try RemoteStoreFactory.make(.sftp)
            _ = try await store.read("manifest.json")
            if let sftp = store as? SFTPStore { await sftp.closeConnection() }
            UserDefaults.standard.set(true, forKey: "sftp.verified")
            setSelected(.sftp, selected: true)
            statusMessage = "Connected to SFTP"
            errorMessage = nil
        } catch {
            if credentialsSaved { SecureVault.remove(account: "sftp") }
            UserDefaults.standard.set(false, forKey: "sftp.verified")
            errorMessage = "SFTP setup failed: \(error.localizedDescription)"
        }
    }

    func disconnect(_ kind: CloudProviderKind) {
        switch kind {
        case .googleDrive, .dropbox, .pCloud:
            SecureVault.remove(account: kind.rawValue + ".oauth")
            if kind == .googleDrive { SecureVault.remove(account: kind.rawValue + ".clientSecret") }
            UserDefaults.standard.removeObject(forKey: kind.rawValue + ".clientID")
        case .webDAV:
            SecureVault.remove(account: "webdav")
            UserDefaults.standard.removeObject(forKey: "webdav.url")
            UserDefaults.standard.removeObject(forKey: "webdav.verified")
        case .sftp:
            SecureVault.remove(account: "sftp")
            UserDefaults.standard.removeObject(forKey: "sftp.verified")
        case .filesFolder:
            UserDefaults.standard.removeObject(forKey: "cloudreader.syncFolderBookmark")
        }
        setSelected(kind, selected: false)
        statusMessage = "Not connected"
    }

    func chooseFilesFolder(_ url: URL) {
        do {
            try FilesFolderStore.saveFolderBookmark(url)
            setSelected(.filesFolder, selected: true)
            statusMessage = "Files folder selected"
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }

    func sync(library: BookLibrary) async {
        guard !isSyncing else {
            syncAgainRequested = true
            return
        }
        let destinations = connectedSelectedProviders
        guard !destinations.isEmpty else {
            errorMessage = nil
            statusMessage = selectedProviders.isEmpty ? "Choose sync destinations" : "Connect a selected destination"
            return
        }
        isSyncing = true
        statusMessage = "Syncing…"
        errorMessage = nil
        defer {
            isSyncing = false
            if syncAgainRequested {
                syncAgainRequested = false
                Task { await sync(library: library) }
            }
        }
        var failures: [CloudProviderKind: String] = [:]
        var finalCounts = (books: 0, conversations: 0)
        let passCount = destinations.count > 1 ? 2 : 1
        for pass in 0..<passCount {
            for (index, provider) in destinations.enumerated() {
                statusMessage = "Syncing \(provider.title) (\(pass * destinations.count + index + 1) of \(passCount * destinations.count))…"
                do {
                    finalCounts = try await syncOnce(to: provider, library: library)
                    failures.removeValue(forKey: provider)
                } catch {
                    failures[provider] = error.localizedDescription
                }
            }
        }

        let succeeded = destinations.filter { failures[$0] == nil }
        if !succeeded.isEmpty { lastSync = .now }
        if failures.isEmpty {
            errorMessage = nil
            statusMessage = "Synced \(finalCounts.books) \(finalCounts.books == 1 ? "book" : "books"), \(finalCounts.conversations) \(finalCounts.conversations == 1 ? "conversation" : "conversations") to \(destinations.count) \(destinations.count == 1 ? "destination" : "destinations")"
        } else {
            let details = destinations.compactMap { provider in failures[provider].map { "\(provider.title): \($0)" } }
            errorMessage = details.joined(separator: "\n")
            statusMessage = succeeded.isEmpty ? "Sync needs attention" : "Synced to \(succeeded.count) of \(destinations.count) destinations"
        }
    }

    private func syncOnce(to provider: CloudProviderKind, library: BookLibrary) async throws -> (books: Int, conversations: Int) {
        let store = try RemoteStoreFactory.make(provider)
        defer { if let sftp = store as? SFTPStore { Task { await sftp.closeConnection() } } }
        let remoteData: Data?
        do {
            remoteData = try await store.read("manifest.json")
        } catch {
            throw CloudSyncError.service("Could not read the sync index: \(error.localizedDescription)")
        }
        var remote = try remoteData.map { try JSONDecoder().decode(RemoteLibraryManifest.self, from: $0) } ?? RemoteLibraryManifest()
        guard remote.schemaVersion == 1 else { throw CloudSyncError.malformedResponse }

        for deletion in remote.deletions { library.applySyncedDeletion(deletion) }
        for deletion in remote.conversationDeletions { library.applySyncedAIConversationDeletion(deletion) }
        var remoteByID: [UUID: SyncedBook] = [:]
        for item in remote.books { remoteByID[item.book.id] = item }
        for conversation in remote.conversations { library.applySyncedAIConversation(conversation) }

        for item in remote.books {
            let local = library.books.first(where: { $0.id == item.book.id })
            guard local.map({ item.book.modifiedAt > $0.modifiedAt }) ?? true else { continue }
            if let deletion = library.deletedBooks.first(where: { $0.bookID == item.book.id }), deletion.deletedAt >= item.book.modifiedAt { continue }
            let contents: Data?
            do {
                contents = try await store.read(objectName(for: item.book))
            } catch {
                throw CloudSyncError.service("Could not download '\(item.book.title)': \(error.localizedDescription)")
            }
            guard let contents else {
                throw CloudSyncError.service("\(provider.title) is missing the book file for '\(item.book.title)'. Its index was left unchanged.")
            }
            guard digest(contents) == item.sha256 else {
                throw CloudSyncError.service("\(provider.title) has a damaged copy of '\(item.book.title)'. Its index was left unchanged.")
            }
            library.applySyncedBook(item.book, contents: contents)
        }

        var merged: [SyncedBook] = []
        for book in library.books {
            if let deletion = library.deletedBooks.first(where: { $0.bookID == book.id }), deletion.deletedAt >= book.modifiedAt { continue }
            guard let contents = library.data(for: book) else { continue }
            let hash = digest(contents)
            if remoteByID[book.id]?.sha256 != hash {
                do {
                    try await store.write(contents, as: objectName(for: book))
                } catch {
                    throw CloudSyncError.service("Could not upload '\(book.title)': \(error.localizedDescription)")
                }
            }
            merged.append(SyncedBook(book: book, sha256: hash))
        }

        var deletionByID: [UUID: BookDeletion] = [:]
        for deletion in remote.deletions + library.deletedBooks {
            if deletionByID[deletion.bookID].map({ $0.deletedAt < deletion.deletedAt }) ?? true { deletionByID[deletion.bookID] = deletion }
        }
        remote.books = merged
        remote.deletions = Array(deletionByID.values)
        var conversationDeletionByID: [UUID: AIConversationDeletion] = [:]
        for deletion in remote.conversationDeletions + library.deletedAIConversations {
            if conversationDeletionByID[deletion.conversationID].map({ $0.deletedAt < deletion.deletedAt }) ?? true {
                conversationDeletionByID[deletion.conversationID] = deletion
            }
        }
        remote.conversations = library.aiConversations.filter { conversation in
            guard let deletion = conversationDeletionByID[conversation.id] else { return true }
            return deletion.deletedAt < conversation.modifiedAt
        }
        remote.conversationDeletions = Array(conversationDeletionByID.values)
        remote.updatedAt = .now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try await store.write(encoder.encode(remote), as: "manifest.json")
        } catch {
            throw CloudSyncError.service("Could not update the sync index: \(error.localizedDescription)")
        }
        return (merged.count, remote.conversations.count)
    }

    private func objectName(for book: Book) -> String { "book-\(book.id.uuidString).\(book.format.rawValue)" }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
