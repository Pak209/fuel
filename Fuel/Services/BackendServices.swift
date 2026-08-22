import CryptoKit
import Foundation
import OSLog
import Security

enum BackendEnvironment: String, Codable, CaseIterable, Sendable {
    case development
    case staging
    case production
}

struct BackendConfiguration: Hashable, Sendable {
    var environment: BackendEnvironment
    var baseURL: URL?

    static func load(bundle: Bundle = .main) -> Self {
        let process = ProcessInfo.processInfo.environment
        let environment = BackendEnvironment(
            rawValue: (process["FUEL_BACKEND_ENVIRONMENT"]
                ?? bundle.object(forInfoDictionaryKey: "FUEL_BACKEND_ENVIRONMENT") as? String
                ?? "development").lowercased()
        ) ?? .development
        let rawURL = process["FUEL_BACKEND_BASE_URL"]
            ?? bundle.object(forInfoDictionaryKey: "FUEL_BACKEND_BASE_URL") as? String
        return .init(environment: environment, baseURL: rawURL.flatMap(URL.init(string:)))
    }

    var isConfigured: Bool { validatedBaseURL != nil }

    var validatedBaseURL: URL? {
        guard let baseURL, let scheme = baseURL.scheme?.lowercased(), let host = baseURL.host, !host.isEmpty else { return nil }
        if scheme == "https" { return baseURL }
        #if DEBUG
        if scheme == "http", host == "localhost" || host == "127.0.0.1" { return baseURL }
        #endif
        return nil
    }
}

enum BackendEndpoint: String, CaseIterable, Sendable {
    case authenticate = "/v1/auth/apple"
    case profile = "/v1/profile"
    case photoAnalysis = "/v1/recognition/jobs"
    case recognitionStatus = "/v1/recognition/status"
    case nutritionSearch = "/v1/nutrition/search"
    case mealSync = "/v1/sync"
    case recommendations = "/v1/recommendations"
    case accountExport = "/v1/account/export"
    case accountDeletion = "/v1/account"
    case remoteConfiguration = "/v1/configuration"

    var requiresAuthentication: Bool { self != .authenticate }
    var maximumRequestBytes: Int {
        switch self {
        case .photoAnalysis: 8_000_000
        default: 1_000_000
        }
    }
}

enum BackendError: LocalizedError, Equatable {
    case notConfigured
    case invalidConfiguration
    case missingCredential
    case invalidPayload
    case payloadTooLarge
    case invalidResponse
    case unauthorized
    case rateLimited
    case server(status: Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Cloud services are not configured. Fuel remains available in local-only mode."
        case .invalidConfiguration: "The cloud service address is invalid or insecure."
        case .missingCredential: "Sign in again to continue syncing."
        case .invalidPayload: "Fuel rejected an invalid cloud request before sending it."
        case .payloadTooLarge: "The item is too large to upload safely."
        case .invalidResponse: "Fuel received an invalid response from the cloud service."
        case .unauthorized: "Your cloud session expired. Sign in again."
        case .rateLimited: "The cloud service is busy. Fuel will retry later."
        case .server(let status): "The cloud service returned error \(status)."
        case .transport: "Fuel couldn’t reach the cloud service. Your changes remain queued."
        }
    }
}

struct BackendHTTPResponse: Sendable {
    var data: Data
    var response: HTTPURLResponse
}

protocol BackendTransport: Sendable {
    func data(for request: URLRequest) async throws -> BackendHTTPResponse
}

struct URLSessionBackendTransport: BackendTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> BackendHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BackendError.invalidResponse }
        return .init(data: data, response: http)
    }
}

enum KeychainCredential: String, CaseIterable, Sendable {
    case accessToken = "backend.access-token"
    case refreshToken = "backend.refresh-token"
    case appleUserIdentifier = "apple.user-identifier"
}

actor KeychainCredentialStore {
    private let service: String

    init(service: String = "com.pak.fuel.credentials") {
        self.service = service
    }

    func save(_ data: Data, for credential: KeychainCredential) throws {
        try delete(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw BackendError.transport("Keychain status \(status)") }
    }

    func save(_ value: String, for credential: KeychainCredential) throws {
        guard let data = value.data(using: .utf8) else { throw BackendError.invalidPayload }
        try save(data, for: credential)
    }

    func data(for credential: KeychainCredential) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw BackendError.transport("Keychain status \(status)")
        }
        return data
    }

    func string(for credential: KeychainCredential) throws -> String? {
        try data(for: credential).flatMap { String(data: $0, encoding: .utf8) }
    }

    func delete(_ credential: KeychainCredential) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BackendError.transport("Keychain status \(status)")
        }
    }

    func deleteAll() throws {
        for credential in KeychainCredential.allCases { try delete(credential) }
    }
}

struct EmptyBackendRequest: Codable, Sendable {}
struct EmptyBackendResponse: Codable, Sendable {}

struct AppleAuthenticationRequest: Codable, Sendable {
    var identityToken: String
    var authorizationCode: String
    var nonce: String
}

struct AuthenticationSessionResponse: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var accountIdentifier: String
}

struct PhotoAnalysisUploadRequest: Codable, Sendable {
    var imageBase64: String
    var mediaType: String
    var retentionConsent: Bool
}

struct RecognitionJobResponse: Codable, Sendable {
    var jobIdentifier: String
    var state: String
    var result: FoodRecognitionResult?
}

struct NutritionSearchRequest: Codable, Sendable { var query: String }
struct NutritionSearchResponse: Codable, Sendable { var foods: [FoodSearchResult] }

struct RemoteRecommendationRequest: Codable, Sendable {
    var date: Date
    var nutrition: DailyNutritionSummary
    var dietaryPreference: DietaryPreference
    var allergies: [String]
    var foodsToAvoid: [String]
}

struct RemoteRecommendationResponse: Codable, Sendable { var recommendation: NutritionRecommendation }

struct SyncOperationPayload: Codable, Hashable, Sendable {
    var idempotencyKey: String
    var entityType: String
    var entityIdentifier: String
    var operation: SyncOperationKind
    var payload: Data
    var clientRevision: Int
    var updatedAt: Date
}

struct SyncConflict: Codable, Hashable, Sendable {
    var entityType: String
    var entityIdentifier: String
    var operation: SyncOperationKind
    var serverRevision: Int
    var serverUpdatedAt: Date
    var serverPayload: Data
}

struct SyncBatchRequest: Codable, Sendable { var operations: [SyncOperationPayload] }
struct SyncBatchResponse: Codable, Sendable {
    var acceptedIdempotencyKeys: [String]
    var conflicts: [SyncConflict]
    var serverRevision: Int
    var remoteChanges: [SyncConflict]?
}

struct AccountExportResponse: Codable, Sendable { var downloadURL: URL; var expiresAt: Date }

struct RemoteFeatureConfiguration: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var minimumAppVersion: String
    var scoringAlgorithmVersion: Int
    var enabledFlags: [String: Bool]
    var expiresAt: Date
}

protocol BackendServicing: Sendable {
    var isConfigured: Bool { get }
    func authenticate(_ request: AppleAuthenticationRequest, idempotencyKey: String) async throws -> AuthenticationSessionResponse
    func uploadRecognition(_ request: PhotoAnalysisUploadRequest, idempotencyKey: String) async throws -> RecognitionJobResponse
    func recognitionStatus(jobIdentifier: String) async throws -> RecognitionJobResponse
    func searchNutrition(_ request: NutritionSearchRequest) async throws -> NutritionSearchResponse
    func synchronize(_ request: SyncBatchRequest, idempotencyKey: String) async throws -> SyncBatchResponse
    func recommendation(_ request: RemoteRecommendationRequest) async throws -> RemoteRecommendationResponse
    func requestAccountExport() async throws -> AccountExportResponse
    func deleteAccount() async throws
    func remoteConfiguration() async throws -> RemoteFeatureConfiguration
}

actor BackendAPIClient: BackendServicing {
    nonisolated let isConfigured: Bool
    private let configuration: BackendConfiguration
    private let transport: any BackendTransport
    private let credentials: KeychainCredentialStore
    private let logger = Logger(subsystem: "com.pak.fuel", category: "Backend")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        configuration: BackendConfiguration = .load(),
        transport: any BackendTransport = URLSessionBackendTransport(),
        credentials: KeychainCredentialStore = .init()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.credentials = credentials
        isConfigured = configuration.isConfigured
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func authenticate(_ request: AppleAuthenticationRequest, idempotencyKey: String) async throws -> AuthenticationSessionResponse {
        try await send(.authenticate, method: "POST", body: request, idempotencyKey: idempotencyKey, authenticated: false)
    }

    func uploadRecognition(_ request: PhotoAnalysisUploadRequest, idempotencyKey: String) async throws -> RecognitionJobResponse {
        try await send(.photoAnalysis, method: "POST", body: request, idempotencyKey: idempotencyKey)
    }

    func recognitionStatus(jobIdentifier: String) async throws -> RecognitionJobResponse {
        guard let encoded = jobIdentifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), !encoded.isEmpty else {
            throw BackendError.invalidPayload
        }
        return try await send(.recognitionStatus, method: "GET", body: EmptyBackendRequest(), querySuffix: "/\(encoded)")
    }

    func searchNutrition(_ request: NutritionSearchRequest) async throws -> NutritionSearchResponse {
        guard !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.query.count <= 160 else {
            throw BackendError.invalidPayload
        }
        return try await send(.nutritionSearch, method: "POST", body: request)
    }

    func synchronize(_ request: SyncBatchRequest, idempotencyKey: String) async throws -> SyncBatchResponse {
        guard request.operations.count <= 100 else { throw BackendError.invalidPayload }
        return try await send(.mealSync, method: "POST", body: request, idempotencyKey: idempotencyKey)
    }

    func recommendation(_ request: RemoteRecommendationRequest) async throws -> RemoteRecommendationResponse {
        try await send(.recommendations, method: "POST", body: request)
    }

    func requestAccountExport() async throws -> AccountExportResponse {
        let response: AccountExportResponse = try await send(.accountExport, method: "POST", body: EmptyBackendRequest())
        guard response.downloadURL.scheme == "https", response.expiresAt > .now else { throw BackendError.invalidResponse }
        return response
    }

    func deleteAccount() async throws {
        let _: EmptyBackendResponse = try await send(.accountDeletion, method: "DELETE", body: EmptyBackendRequest())
    }

    func remoteConfiguration() async throws -> RemoteFeatureConfiguration {
        try await send(.remoteConfiguration, method: "GET", body: EmptyBackendRequest())
    }

    private func send<Request: Encodable, Response: Decodable>(
        _ endpoint: BackendEndpoint,
        method: String,
        body: Request,
        idempotencyKey: String? = nil,
        authenticated: Bool? = nil,
        querySuffix: String = ""
    ) async throws -> Response {
        guard isConfigured else { throw BackendError.notConfigured }
        guard let baseURL = configuration.validatedBaseURL else { throw BackendError.invalidConfiguration }
        let payload = method == "GET" ? Data() : try encoder.encode(body)
        guard payload.count <= endpoint.maximumRequestBytes else { throw BackendError.payloadTooLarge }
        var request = URLRequest(url: baseURL.appending(path: endpoint.rawValue + querySuffix))
        request.httpMethod = method
        request.httpBody = payload.isEmpty ? nil : payload
        request.timeoutInterval = endpoint == .photoAnalysis ? 45 : 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !payload.isEmpty { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if authenticated ?? endpoint.requiresAuthentication {
            guard let token = try await credentials.string(for: .accessToken), !token.isEmpty else { throw BackendError.missingCredential }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var lastError: Error = BackendError.invalidResponse
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let result = try await transport.data(for: request)
                guard result.data.count <= 5_000_000 else { throw BackendError.invalidResponse }
                switch result.response.statusCode {
                case 200..<300:
                    if Response.self == EmptyBackendResponse.self, result.data.isEmpty {
                        return EmptyBackendResponse() as! Response
                    }
                    return try decoder.decode(Response.self, from: result.data)
                case 401, 403: throw BackendError.unauthorized
                case 429:
                    lastError = BackendError.rateLimited
                case 408, 500...599:
                    lastError = BackendError.server(status: result.response.statusCode)
                default:
                    throw BackendError.server(status: result.response.statusCode)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as BackendError where error == .unauthorized || error == .invalidPayload || error == .payloadTooLarge {
                throw error
            } catch {
                lastError = error
            }
            if attempt < 2 {
                let nanoseconds = UInt64((attempt + 1) * 500_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        }
        logger.error("Backend request failed endpoint=\(endpoint.rawValue, privacy: .public) error=\(String(describing: type(of: lastError)), privacy: .public)")
        if let backendError = lastError as? BackendError { throw backendError }
        throw BackendError.transport(String(describing: type(of: lastError)))
    }
}

struct AppleSignInPayload: Sendable {
    var userIdentifier: String
    var fullName: PersonNameComponents?
    var email: String?
    var identityToken: Data
    var authorizationCode: Data
    var nonce: String
}

enum SignInNonce {
    static func generate(length: Int = 32) throws -> String {
        precondition(length > 0)
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw BackendError.transport("Secure random status \(status)") }
        for byte in bytes { result.append(alphabet[Int(byte) % alphabet.count]) }
        return result
    }

    static func hashed(_ rawValue: String) -> String {
        SHA256.hash(data: Data(rawValue.utf8)).hexString
    }
}

struct AccountSessionResult: Hashable, Sendable {
    var userIdentifierHash: String
    var displayName: String?
    var emailHint: String?
    var cloudConnected: Bool
}

actor AccountSessionService {
    private let backend: any BackendServicing
    private let credentials: KeychainCredentialStore

    init(backend: any BackendServicing, credentials: KeychainCredentialStore = .init()) {
        self.backend = backend
        self.credentials = credentials
    }

    func signIn(_ payload: AppleSignInPayload) async throws -> AccountSessionResult {
        guard !payload.userIdentifier.isEmpty,
              let identityToken = String(data: payload.identityToken, encoding: .utf8),
              let authorizationCode = String(data: payload.authorizationCode, encoding: .utf8),
              !identityToken.isEmpty,
              !authorizationCode.isEmpty else { throw BackendError.invalidPayload }

        try await credentials.save(payload.userIdentifier, for: .appleUserIdentifier)
        var cloudConnected = false
        if backend.isConfigured {
            let response = try await backend.authenticate(
                .init(identityToken: identityToken, authorizationCode: authorizationCode, nonce: payload.nonce),
                idempotencyKey: SHA256.hash(data: payload.authorizationCode).hexString
            )
            guard !response.accessToken.isEmpty, !response.refreshToken.isEmpty else { throw BackendError.invalidResponse }
            try await credentials.save(response.accessToken, for: .accessToken)
            try await credentials.save(response.refreshToken, for: .refreshToken)
            cloudConnected = true
        }

        return .init(
            userIdentifierHash: SHA256.hash(data: Data(payload.userIdentifier.utf8)).hexString,
            displayName: payload.fullName.flatMap { PersonNameComponentsFormatter().string(from: $0).nilIfEmpty },
            emailHint: payload.email.map(maskEmail),
            cloudConnected: cloudConnected
        )
    }

    func signOut() async throws {
        try await credentials.deleteAll()
    }

    func deleteRemoteAccount() async throws {
        if backend.isConfigured { try await backend.deleteAccount() }
        try await credentials.deleteAll()
    }

    private func maskEmail(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, let first = parts[0].first else { return "Hidden by Apple" }
        return "\(first)•••@\(parts[1])"
    }
}

private extension Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
