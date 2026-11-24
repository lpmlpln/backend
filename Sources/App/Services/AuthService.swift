import Foundation
import Fluent
import JWTKit
import MealPlannerCore
import Vapor

struct AccessTokenPayload: JWTPayload, Sendable {
    var sub: SubjectClaim
    var exp: ExpirationClaim
    var iat: IssuedAtClaim
    var deviceID: String
    var isAdmin: Bool

    init(userID: UUID, deviceID: UUID, isAdmin: Bool, ttlSeconds: Int) {
        let now = Date()
        sub = SubjectClaim(value: userID.uuidString)
        iat = IssuedAtClaim(value: now)
        exp = ExpirationClaim(value: now.addingTimeInterval(TimeInterval(ttlSeconds)))
        self.deviceID = deviceID.uuidString
        self.isAdmin = isAdmin
    }

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }

    var userID: UUID? { UUID(uuidString: sub.value) }
    var deviceUUID: UUID? { UUID(uuidString: deviceID) }
}

actor JWTManager {
    private let keys: JWTKeyCollection

    init(secret: String) async {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: secret), digestAlgorithm: .sha256)
        self.keys = keys
    }

    func sign(_ payload: AccessTokenPayload) async throws -> String {
        try await keys.sign(payload)
    }

    func verify(_ token: String) async throws -> AccessTokenPayload {
        try await keys.verify(token, as: AccessTokenPayload.self)
    }
}

enum JWTManagerKey: StorageKey {
    typealias Value = JWTManager
}

extension Application {
    var jwtManager: JWTManager? {
        get { storage[JWTManagerKey.self] }
        set { storage[JWTManagerKey.self] = newValue }
    }
}

extension Request {
    var jwtManager: JWTManager? {
        application.jwtManager
    }
}

struct AuthService: Sendable {
    let db: any Database
    let emailSender: any EmailSender
    let baseURL: String
    let jwt: JWTManager
    let accessTTL: Int
    let refreshTTLDays: Int
    let magicLinkTTLSeconds: Int

    func startMagicLink(email rawEmail: String, client: String, requestIP: String?, userAgent: String?, logger: Logger) async throws {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.contains("@"), email.count <= 320 else {
            throw AppError.validation("A valid email address is required.")
        }

        let existing = try await UserModel.query(on: db)
            .filter(\.$email == email)
            .first()

        let token = TokenHasher.randomURLSafe()
        let hash = TokenHasher.sha256(token)
        let record = MagicLinkTokenModel(
            email: email,
            userID: existing?.id,
            tokenHash: hash,
            client: client,
            expiresAt: Date().addingTimeInterval(TimeInterval(magicLinkTTLSeconds)),
            requestIP: requestIP,
            userAgent: userAgent
        )
        try await record.save(on: db)

        let path = client == "admin" ? "admin" : "auth"
        var components = URLComponents(string: "\(baseURL)/\(path)/verify")
        components?.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "client", value: client),
        ]
        guard let link = components?.url else {
            throw AppError.server("Could not construct the magic link.")
        }

        try await emailSender.sendMagicLink(to: email, link: link, client: client, logger: logger)
    }

    /// Returns the user and a refresh token after verifying a magic-link token.
    func verifyMagicLink(token: String, email rawEmail: String, client: String, deviceID: UUID, deviceName: String) async throws -> (UserModel, String) {
        let email = rawEmail.lowercased()
        let hash = TokenHasher.sha256(token)

        guard let record = try await MagicLinkTokenModel.query(on: db)
            .filter(\.$tokenHash == hash)
            .first()
        else {
            throw AppError(.unauthorized, status: .unauthorized, message: "Invalid sign-in link.")
        }

        guard record.email == email, record.client == client else {
            throw AppError(.unauthorized, status: .unauthorized, message: "Invalid sign-in link.")
        }
        guard record.consumedAt == nil else {
            throw AppError(.magicLinkUsed, status: .unauthorized, message: "This sign-in link was already used.")
        }
        guard record.expiresAt > Date() else {
            throw AppError(.magicLinkExpired, status: .unauthorized, message: "This sign-in link has expired.")
        }

        let user: UserModel
        if let existing = try await UserModel.query(on: db).filter(\.$email == email).first() {
            user = existing
        } else {
            user = UserModel(email: email, displayName: String(email.split(separator: "@").first ?? "User"))
            try await user.save(on: db)
        }
        guard user.isDisabled == false else {
            throw AppError.forbidden("This account is disabled.")
        }

        record.consumedAt = Date()
        record.$user.id = user.id
        try await record.save(on: db)

        return try await (user, issueRefreshToken(user: user, deviceID: deviceID, deviceName: deviceName))
    }

    func signInWithApple(
        identityToken: String,
        nonce: String,
        verifier: any AppleTokenVerifier,
        deviceID: UUID,
        deviceName: String
    ) async throws -> (UserModel, String) {
        let identity = try await verifier.verify(identityToken, nonce: nonce)
        let email = identity.email.lowercased()

        let user: UserModel
        if let bySubject = try await UserModel.query(on: db)
            .filter(\.$appleSubjectID == identity.subject)
            .first() {
            user = bySubject
        } else if let byEmail = try await UserModel.query(on: db).filter(\.$email == email).first() {
            user = byEmail
            user.appleSubjectID = identity.subject
            try await user.save(on: db)
        } else {
            user = UserModel(
                email: email,
                displayName: identity.email.split(separator: "@").first.map(String.init) ?? "User",
                appleSubjectID: identity.subject
            )
            try await user.save(on: db)
        }
        guard user.isDisabled == false else {
            throw AppError.forbidden("This account is disabled.")
        }

        return try await (user, issueRefreshToken(user: user, deviceID: deviceID, deviceName: deviceName))
    }

    func issueRefreshToken(user: UserModel, deviceID: UUID, deviceName: String) async throws -> String {
        guard let userID = user.id else { throw AppError.server("User has no ID.") }

        let device = try await UserDeviceModel.find(deviceID, on: db) ?? UserDeviceModel(
            id: deviceID,
            userID: userID,
            name: deviceName,
            platform: "ios"
        )
        if device.$user.id != userID {
            device.$user.id = userID
        }
        device.lastSeenAt = Date()
        if device.id != nil {
            try await device.save(on: db)
        } else {
            device.id = UUID()
            try await device.create(on: db)
        }

        let token = TokenHasher.randomURLSafe()
        let record = RefreshTokenModel(
            userID: userID,
            deviceID: deviceID,
            tokenHash: TokenHasher.sha256(token),
            expiresAt: Date().addingTimeInterval(TimeInterval(refreshTTLDays * 86_400))
        )
        try await record.save(on: db)
        return token
    }

    func issueAccessToken(user: UserModel, deviceID: UUID) async throws -> String {
        guard let userID = user.id else { throw AppError.server("User has no ID.") }
        let payload = AccessTokenPayload(
            userID: userID,
            deviceID: deviceID,
            isAdmin: user.isAdmin,
            ttlSeconds: accessTTL
        )
        return try await jwt.sign(payload)
    }

    func refresh(refreshToken: String) async throws -> (UserModel, UUID, String) {
        let hash = TokenHasher.sha256(refreshToken)
        guard let record = try await RefreshTokenModel.query(on: db)
            .filter(\.$tokenHash == hash)
            .first()
        else {
            throw AppError.unauthorized("Invalid refresh token.")
        }
        guard record.revokedAt == nil else {
            throw AppError.unauthorized("Refresh token has been revoked.")
        }
        guard record.expiresAt > Date() else {
            throw AppError.unauthorized("Refresh token has expired.")
        }
        guard let user = try await UserModel.find(record.$user.id, on: db) else {
            throw AppError.unauthorized("User not found.")
        }
        guard !user.isDisabled else {
            throw AppError.forbidden("This account is disabled.")
        }

        // Rotate: revoke the old token and issue a fresh one.
        record.revokedAt = Date()
        try await record.save(on: db)
        let newToken = try await issueRefreshToken(
            user: user,
            deviceID: record.$device.id,
            deviceName: "device"
        )
        return (user, record.$device.id, newToken)
    }

    func logout(refreshToken: String) async throws {
        let hash = TokenHasher.sha256(refreshToken)
        guard let record = try await RefreshTokenModel.query(on: db)
            .filter(\.$tokenHash == hash)
            .first()
        else { return }
        record.revokedAt = Date()
        try await record.save(on: db)
    }

    func revokeAllTokens(userID: UUID) async throws {
        let tokens = try await RefreshTokenModel.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
        for token in tokens where token.revokedAt == nil {
            token.revokedAt = Date()
            try await token.save(on: db)
        }
    }
}

struct AppleIdentity: Sendable {
    let subject: String
    let email: String
}

protocol AppleTokenVerifier: Sendable {
    func verify(_ identityToken: String, nonce: String) async throws -> AppleIdentity
}

/// Verifies Apple identity tokens against Apple's JWKS endpoint.
struct RemoteAppleTokenVerifier: AppleTokenVerifier {
    struct Payload: JWTPayload, Sendable {
        var iss: IssuerClaim
        var aud: AudienceClaim
        var exp: ExpirationClaim
        var sub: SubjectClaim
        var email: String?
        var nonceSupported: Bool?
        var nonce: String?

        enum CodingKeys: String, CodingKey {
            case iss, aud, exp, sub, email
            case nonceSupported = "nonce_supported"
            case nonce
        }

        func verify(using algorithm: some JWTAlgorithm) async throws {
            try exp.verifyNotExpired()
            guard iss.value == "https://appleid.apple.com" else {
                throw AppError.appleTokenInvalid
            }
        }
    }

    let jwksURL: URL
    let audience: String
    let client: any Client

    func verify(_ identityToken: String, nonce: String) async throws -> AppleIdentity {
        let response = try await client.get(URI(string: jwksURL.absoluteString)).get()
        guard (200..<300).contains(response.status.code) else {
            throw AppError.appleTokenInvalid
        }
        let json = response.body.map { String(buffer: $0) } ?? ""
        let keys = JWTKeyCollection()
        try await keys.add(jwksJSON: json)

        let payload = try await keys.verify(
            identityToken,
            as: Payload.self,
            iteratingKeys: true
        )
        guard payload.aud.value.contains(audience) else {
            throw AppError.appleTokenInvalid
        }
        if payload.nonceSupported == true {
            let supplied = TokenHasher.sha256(nonce)
            guard payload.nonce == supplied else {
                throw AppError.appleTokenInvalid
            }
        }
        guard let email = payload.email else {
            throw AppError.appleTokenInvalid
        }
        return AppleIdentity(subject: payload.sub.value, email: email)
    }
}

extension AppError {
    static let appleTokenInvalid = AppError(.appleTokenInvalid, status: .unauthorized, message: "Invalid Apple identity token.")
}
