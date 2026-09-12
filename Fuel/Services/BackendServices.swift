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

    /// The only construction path. Taking the whole `UserPreferences` value binds
    /// `retentionConsent` to the user's stored decision instead of a literal at the call site,
    /// so a future upload path cannot silently ship an unconsented retention flag. The
    /// memberwise initializer is deliberately not reinstated.
    init(imageData: Data, mediaType: String = "image/jpeg", preferences: UserPreferences) throws {
        guard !imageData.isEmpty else { throw BackendError.invalidPayload }
        guard imageData.count <= 5_000_000 else { throw BackendError.payloadTooLarge }
        guard ["image/jpeg", "image/png", "image/heic"].contains(mediaType) else {
            throw BackendError.invalidPayload
        }
        imageBase64 = imageData.base64EncodedString()
        self.mediaType = mediaType
        retentionConsent = preferences.mealPhotoRetentionConsent
    }
}

/// The account document behind `BackendEndpoint.profile`: the three values Fuel already
/// mirrors through the sync queue, returned together with the server's revision counter.
struct ProfileResponse: Codable, Hashable, Sendable {
    var profile: UserProfile
    var targets: DailyTargets
    var preferences: UserPreferences
    var serverRevision: Int
    var updatedAt: Date
}

struct ProfileUpdateRequest: Codable, Hashable, Sendable {
    var profile: UserProfile
    var targets: DailyTargets
    var preferences: UserPreferences
    var clientRevision: Int

    /// Rejects values Fuel should never put on the wire before the request leaves the device.
    func validated() throws -> Self {
        guard clientRevision >= 0 else { throw BackendError.invalidPayload }
        let name = profile.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, profile.ageRange.count <= 32, profile.activityLevel.count <= 40 else {
            throw BackendError.invalidPayload
        }
        guard TimeZone(identifier: profile.timeZoneIdentifier) != nil else { throw BackendError.invalidPayload }
        guard profile.heightCM.isFinite, (60...260).contains(profile.heightCM),
              profile.weightKG.isFinite, (20...400).contains(profile.weightKG) else {
            throw BackendError.invalidPayload
        }
        for list in [profile.allergies, profile.foodsToAvoid] {
            guard list.count <= 40, list.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else {
                throw BackendError.invalidPayload
            }
        }
        guard (1_000...6_000).contains(targets.calories),
              targets.proteinGrams.isFinite, targets.carbohydrateGrams.isFinite,
              targets.fatGrams.isFinite, targets.fiberGrams.isFinite,
              targets.hydrationMilliliters.isFinite else {
            throw BackendError.invalidPayload
        }
        return self
    }
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

struct SyncBatchRequest: Codable, Sendable {
    var operations: [SyncOperationPayload]
    /// The last completely applied account revision. Nil starts the change feed at zero.
    var sinceRevision: Int?

    init(operations: [SyncOperationPayload], sinceRevision: Int? = nil) {
        self.operations = operations
        self.sinceRevision = sinceRevision
    }
}
struct SyncBatchResponse: Codable, Sendable {
    var acceptedIdempotencyKeys: [String]
    var conflicts: [SyncConflict]
    /// A fully represented change-feed cursor. A paginated server must not advance this
    /// past omitted remote changes; the client cannot infer missing records from a revision gap.
    var serverRevision: Int
    var remoteChanges: [SyncConflict]?
}

/// A normalized identity for comparisons across queue records and server envelopes.
struct SyncEntityIdentity: Hashable, Sendable {
    let entityType: String
    let entityIdentifier: String

    init?(entityType: String, entityIdentifier: String) {
        self.entityType = entityType
        switch entityType {
        case "meal", "hydration":
            guard let id = UUID(uuidString: entityIdentifier) else { return nil }
            self.entityIdentifier = id.uuidString
        case "profile", "preferences":
            guard entityIdentifier == "primary" else { return nil }
            self.entityIdentifier = entityIdentifier
        case "targets":
            guard entityIdentifier == "current" else { return nil }
            self.entityIdentifier = entityIdentifier
        default:
            return nil
        }
    }
}

/// Validates the whole wire envelope before a caller acknowledges queue entries or applies
/// any remote values. Both the HTTP client and the sync engine use this boundary so a
/// replacement transport cannot bypass it. Entity payload semantics are validated separately.
enum SyncContractValidator {
    static let maximumOperations = 100
    static let maximumRemoteChanges = 500
    static let maximumEntityPayloadBytes = 500_000
    static let maximumResponseBytes = 5_000_000

    /// Selects an ordered prefix that can actually be sent, including base64 and JSON
    /// overhead. Records beyond the returned prefix remain pending for the next batch.
    /// An invalid or individually oversized examined record is an explicit error; a valid
    /// record that only exceeds the combined byte budget ends the batch without skipping it.
    static func makeBatchRequest(
        from orderedOperations: [SyncOperationPayload],
        sinceRevision: Int? = nil
    ) throws -> SyncBatchRequest {
        var request = SyncBatchRequest(operations: [], sinceRevision: sinceRevision)
        try validateRequest(request)

        for operation in orderedOperations.prefix(maximumOperations) {
            // Distinguish an unsendable record from two sendable records whose combined
            // encoded body is too large. Only the latter can be retried as another batch.
            try validateRequest(.init(operations: [operation], sinceRevision: sinceRevision))
            var candidate = request
            candidate.operations.append(operation)
            do {
                try validateRequest(candidate)
                request = candidate
            } catch BackendError.payloadTooLarge {
                guard !request.operations.isEmpty else { throw BackendError.payloadTooLarge }
                break
            }
        }
        return request
    }

    static func validateRequest(_ request: SyncBatchRequest) throws {
        guard request.operations.count <= maximumOperations,
              (request.sinceRevision ?? 0) >= 0 else { throw BackendError.invalidPayload }

        var keys = Set<String>()
        var entities = Set<SyncEntityIdentity>()
        var payloadBytes = 0
        for operation in request.operations {
            guard isValidIdempotencyKey(operation.idempotencyKey),
                  keys.insert(operation.idempotencyKey).inserted,
                  let identity = entityIdentity(type: operation.entityType, identifier: operation.entityIdentifier),
                  entities.insert(identity).inserted,
                  operation.clientRevision >= 0,
                  operation.updatedAt.timeIntervalSince1970.isFinite,
                  isSupportedOperation(operation.operation, for: operation.entityType) else {
                throw BackendError.invalidPayload
            }
            guard operation.payload.count <= maximumEntityPayloadBytes else { throw BackendError.payloadTooLarge }
            payloadBytes += operation.payload.count
            guard payloadBytes <= BackendEndpoint.mealSync.maximumRequestBytes else { throw BackendError.payloadTooLarge }
        }

        guard try encodedSize(request) <= BackendEndpoint.mealSync.maximumRequestBytes else {
            throw BackendError.payloadTooLarge
        }
    }

    static func validateResponse(_ response: SyncBatchResponse, for request: SyncBatchRequest) throws {
        try validateRequest(request)
        let sinceRevision = request.sinceRevision ?? 0
        guard response.serverRevision >= sinceRevision,
              response.acceptedIdempotencyKeys.count <= request.operations.count,
              response.conflicts.count <= request.operations.count,
              (response.remoteChanges?.count ?? 0) <= maximumRemoteChanges else {
            throw BackendError.invalidResponse
        }

        let submittedKeys = Set(request.operations.map(\.idempotencyKey))
        let acceptedKeys = Set(response.acceptedIdempotencyKeys)
        guard acceptedKeys.count == response.acceptedIdempotencyKeys.count,
              acceptedKeys.isSubset(of: submittedKeys) else { throw BackendError.invalidResponse }

        let submittedEntities = Set(request.operations.compactMap {
            entityIdentity(type: $0.entityType, identifier: $0.entityIdentifier)
        })
        var conflictEntities = Set<SyncEntityIdentity>()
        var payloadBytes = 0
        for conflict in response.conflicts {
            let identity = try validateRemoteEnvelope(conflict, maximumRevision: response.serverRevision)
            payloadBytes += conflict.serverPayload.count
            guard payloadBytes <= maximumResponseBytes else { throw BackendError.invalidResponse }
            guard submittedEntities.contains(identity), conflictEntities.insert(identity).inserted else {
                throw BackendError.invalidResponse
            }
        }

        // A partial or contradictory outcome must leave the entire local batch untouched.
        for operation in request.operations {
            guard let identity = entityIdentity(type: operation.entityType, identifier: operation.entityIdentifier),
                  acceptedKeys.contains(operation.idempotencyKey) != conflictEntities.contains(identity) else {
                throw BackendError.invalidResponse
            }
        }

        var remoteEntities = Set<SyncEntityIdentity>()
        var lastRemoteRevision = sinceRevision
        for change in response.remoteChanges ?? [] {
            let identity = try validateRemoteEnvelope(change, maximumRevision: response.serverRevision)
            payloadBytes += change.serverPayload.count
            guard payloadBytes <= maximumResponseBytes else { throw BackendError.invalidResponse }
            guard change.serverRevision > lastRemoteRevision,
                  remoteEntities.insert(identity).inserted,
                  !conflictEntities.contains(identity) else { throw BackendError.invalidResponse }
            lastRemoteRevision = change.serverRevision
        }

        // An accepted entity can also appear in the feed as the canonical server echo.
        // The engine still protects newer local edits before applying that echo.
        guard try encodedSize(response) <= maximumResponseBytes else { throw BackendError.invalidResponse }
    }

    private static func entityIdentity(type: String, identifier: String) -> SyncEntityIdentity? {
        SyncEntityIdentity(entityType: type, entityIdentifier: identifier)
    }

    private static func isSupportedOperation(_ operation: SyncOperationKind, for entityType: String) -> Bool {
        operation != .delete || entityType == "meal" || entityType == "hydration"
    }

    private static func isValidIdempotencyKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 128 else { return false }
        return key.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || byte == 45 || byte == 46 || byte == 95
        }
    }

    private static func validateRemoteEnvelope(_ change: SyncConflict, maximumRevision: Int) throws -> SyncEntityIdentity {
        guard let identity = entityIdentity(type: change.entityType, identifier: change.entityIdentifier),
              isSupportedOperation(change.operation, for: change.entityType),
              change.serverRevision >= 0, change.serverRevision <= maximumRevision,
              change.serverUpdatedAt.timeIntervalSince1970.isFinite,
              change.serverPayload.count <= maximumEntityPayloadBytes else { throw BackendError.invalidResponse }
        return identity
    }

    private static func encodedSize<Value: Encodable>(_ value: Value) throws -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value).count
    }
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
    func fetchProfile() async throws -> ProfileResponse
    func updateProfile(_ request: ProfileUpdateRequest) async throws -> ProfileResponse
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

    func fetchProfile() async throws -> ProfileResponse {
        let response: ProfileResponse = try await send(.profile, method: "GET", body: EmptyBackendRequest())
        guard response.serverRevision >= 0,
              !response.profile.firstName.isEmpty,
              response.profile.heightCM.isFinite,
              response.profile.weightKG.isFinite,
              response.targets.calories > 0 else { throw BackendError.invalidResponse }
        return response
    }

    func updateProfile(_ request: ProfileUpdateRequest) async throws -> ProfileResponse {
        let validated = try request.validated()
        let payload = try encoder.encode(validated)
        guard payload.count <= BackendEndpoint.profile.maximumRequestBytes else { throw BackendError.payloadTooLarge }
        // Derived from the payload so a retried write reuses its key while an edited one gets a new key.
        let idempotencyKey = SHA256.hash(data: payload).hexString
        return try await send(.profile, method: "PUT", body: validated, idempotencyKey: idempotencyKey)
    }

    func uploadRecognition(_ request: PhotoAnalysisUploadRequest, idempotencyKey: String) async throws -> RecognitionJobResponse {
        guard !request.imageBase64.isEmpty else { throw BackendError.invalidPayload }
        return try await send(.photoAnalysis, method: "POST", body: request, idempotencyKey: idempotencyKey)
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
        try SyncContractValidator.validateRequest(request)
        let response: SyncBatchResponse = try await send(.mealSync, method: "POST", body: request, idempotencyKey: idempotencyKey)
        try SyncContractValidator.validateResponse(response, for: request)
        return response
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
