import Fluent
import Foundation
import MealPlannerCore
import Vapor

extension Request {
    var userID: UUID? {
        auth.get(AuthenticatedUser.self)?.userID
    }

    func requireUserID() throws -> UUID {
        guard let userID = userID else { throw AppError.unauthorized() }
        return userID
    }

    var authenticatedUser: AuthenticatedUser? {
        auth.get(AuthenticatedUser.self)
    }
}

struct AuthenticatedUser: Authenticatable, Sendable {
    let userID: UUID
    let deviceID: UUID
    let isAdmin: Bool

    func requiresFreshAuthentication() -> Bool { false }
}

struct BearerAuthenticator: AsyncRequestAuthenticator {
    func authenticate(request: Request) async throws {
        guard let header = request.headers.bearerAuthorization?.token else { return }
        do {
            let payload = try await request.jwtManager?.verify(header)
            guard let payload, let userID = payload.userID, let deviceID = payload.deviceUUID else { return }
            request.auth.login(
                AuthenticatedUser(
                    userID: userID,
                    deviceID: deviceID,
                    isAdmin: payload.isAdmin
                )
            )
        } catch {
            // Invalid tokens are treated as unauthenticated.
        }
    }
}

struct AuthController: Sendable {
    func register(routes: some RoutesBuilder) {
        routes.post("auth", "magic-link", use: requestMagicLink)
        routes.post("auth", "verify", use: verifyMagicLink)
        routes.get("auth", "verify", use: openMagicLink)
        routes.post("auth", "apple", use: appleSignIn)
        routes.post("auth", "refresh", use: refresh)
        routes.post("auth", "logout", use: logout)
        routes.get("me", use: me)
        routes.delete("me", use: deleteAccount)
        routes.post("devices", use: registerDevice)
    }

    private func authService(_ request: Request) -> AuthService {
        AuthService(
            db: request.db,
            emailSender: request.application.emailSender,
            baseURL: request.application.appBaseURL,
            jwt: request.application.jwtManager ?? fatalJWT(),
            accessTTL: request.application.accessTTL,
            refreshTTLDays: request.application.refreshTTLDays,
            magicLinkTTLSeconds: request.application.magicLinkTTL
        )
    }

    private func fatalJWT() -> JWTManager {
        fatalError("JWT manager is not configured.")
    }

    @Sendable
    func requestMagicLink(_ request: Request) async throws -> MagicLinkResponse {
        let body = try request.content.decode(MagicLinkRequest.self)
        let client = request.headers.first(name: "X-Client") ?? "ios"
        try await authService(request).startMagicLink(
            email: body.email,
            client: client,
            requestIP: request.remoteAddress?.ipAddress,
            userAgent: request.headers.first(name: .userAgent),
            logger: request.logger
        )
        return MagicLinkResponse()
    }

    @Sendable
    func verifyMagicLink(_ request: Request) async throws -> TokenPair {
        struct Body: Codable {
            var token: String
            var email: String
            var client: String = "ios"
            var deviceID: UUID = UUID()
            var deviceName: String = "iPhone"
        }
        let body = try request.content.decode(Body.self)
        let (user, refreshToken) = try await authService(request).verifyMagicLink(
            token: body.token,
            email: body.email,
            client: body.client,
            deviceID: body.deviceID,
            deviceName: body.deviceName
        )
        let access = try await authService(request).issueAccessToken(user: user, deviceID: body.deviceID)
        return TokenPair(
            accessToken: access,
            refreshToken: refreshToken,
            expiresInSeconds: request.application.accessTTL,
            user: try user.dto()
        )
    }

    @Sendable
    func openMagicLink(_ request: Request) async throws -> Response {
        guard let token = request.query[String.self, at: "token"],
              let email = request.query[String.self, at: "email"]
        else {
            throw AppError.validation("The sign-in link is missing parameters.")
        }
        let client = request.query[String.self, at: "client"] ?? "ios"
        let host = URL(string: request.application.appBaseURL)!.host()
        let callback = "mealplanner://\(host)/auth/callback?token=\(token)&email=\(email)&client=\(client)"
        let html = """
        <html><body><p>Opening MealPlanner…</p>
        <script>window.location.href = "\(callback)";</script>
        <a href="\(callback)">Open MealPlanner</a></body></html>
        """
        return Response(
            status: .ok,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: .init(string: html)
        )
    }

    @Sendable
    func appleSignIn(_ request: Request) async throws -> TokenPair {
        let body = try request.content.decode(AppleSignInRequest.self)
        guard let verifier = request.application.appleTokenVerifier else {
            throw AppError.server("Apple sign-in is not configured.")
        }
        let deviceID = body.authorizationCode.flatMap(UUID.init(uuidString:)) ?? UUID()
        let (user, refreshToken) = try await authService(request).signInWithApple(
            identityToken: body.identityToken,
            nonce: body.nonce,
            verifier: verifier,
            deviceID: deviceID,
            deviceName: "Apple device"
        )
        let access = try await authService(request).issueAccessToken(user: user, deviceID: deviceID)
        return TokenPair(
            accessToken: access,
            refreshToken: refreshToken,
            expiresInSeconds: request.application.accessTTL,
            user: try user.dto()
        )
    }

    @Sendable
    func refresh(_ request: Request) async throws -> TokenPair {
        let body = try request.content.decode(RefreshRequest.self)
        let (user, deviceID, refreshToken) = try await authService(request).refresh(refreshToken: body.refreshToken)
        let access = try await authService(request).issueAccessToken(user: user, deviceID: deviceID)
        return TokenPair(
            accessToken: access,
            refreshToken: refreshToken,
            expiresInSeconds: request.application.accessTTL,
            user: try user.dto()
        )
    }

    @Sendable
    func logout(_ request: Request) async throws -> HTTPStatus {
        let body = try request.content.decode(RefreshRequest.self)
        try await authService(request).logout(refreshToken: body.refreshToken)
        return .noContent
    }

    @Sendable
    func me(_ request: Request) async throws -> UserDTO {
        guard let user = try await UserModel.find(request.requireUserID(), on: request.db) else {
            throw AppError.unauthorized()
        }
        return try user.dto()
    }

    @Sendable
    func deleteAccount(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        guard let user = try await UserModel.find(userID, on: request.db) else {
            throw AppError.unauthorized()
        }

        let plans = try await PlanningService(db: request.db, access: AccessPolicy(db: request.db))
            .accessiblePlans(userID: userID)
        for plan in plans where plan.$owner.id == userID {
            try await plan.delete(on: request.db)
        }

        let shares = try await RecipeShareModel.query(on: request.db)
            .filter(\.$sharedWith.$id == userID).all()
        for share in shares { try await share.delete(on: request.db) }

        let memberships = try await PlanMemberModel.query(on: request.db)
            .filter(\.$user.$id == userID).all()
        for member in memberships { try await member.delete(on: request.db) }

        try await authService(request).revokeAllTokens(userID: userID)

        let anonymized = "deleted-\(userID.uuidString)@example.invalid"
        user.email = anonymized
        user.displayName = "Deleted user"
        user.appleSubjectID = nil
        user.isDisabled = true
        user.deletedAt = Date()
        try await user.save(on: request.db)

        try await AuditLogModel(
            actorUserID: userID,
            action: "user.delete",
            entityType: "user",
            entityID: userID
        ).save(on: request.db)

        return .noContent
    }

    @Sendable
    func registerDevice(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        let body = try request.content.decode(DeviceRegistration.self)
        if let existing = try await UserDeviceModel.find(body.deviceID, on: request.db) {
            guard existing.$user.id == userID else { throw AppError.forbidden() }
            existing.name = body.name
            existing.platform = body.platform
            existing.lastSeenAt = Date()
            try await existing.save(on: request.db)
        } else {
            try await UserDeviceModel(
                id: body.deviceID,
                userID: userID,
                name: body.name,
                platform: body.platform
            ).save(on: request.db)
        }
        return .ok
    }
}
