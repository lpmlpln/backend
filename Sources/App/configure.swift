import Fluent
import FluentPostgresDriver
import Foundation
import JWTKit
import MealPlannerCore
import Vapor

extension Application {
    var appBaseURL: String {
        Environment.get("APP_BASE_URL") ?? "http://localhost:8080"
    }

    var accessTTL: Int {
        Int(Environment.get("JWT_ACCESS_TTL_SECONDS") ?? "") ?? 900
    }

    var refreshTTLDays: Int {
        Int(Environment.get("REFRESH_TOKEN_TTL_DAYS") ?? "") ?? 30
    }

    var magicLinkTTL: Int {
        Int(Environment.get("MAGIC_LINK_TTL_SECONDS") ?? "") ?? 900
    }

    var emailSender: any EmailSender {
        get { storage[EmailSenderKey.self] ?? defaultEmailSender }
        set { storage[EmailSenderKey.self] = newValue }
    }

    private var defaultEmailSender: any EmailSender {
        if let key = Environment.get("SMTP2GO_API_KEY"), !key.isEmpty {
            return SMTP2GOEmailSender(
                apiKey: key,
                from: Environment.get("EMAIL_FROM") ?? "MealPlanner <login@example.com>"
            )
        }
        return ConsoleEmailSender()
    }

    var appleTokenVerifier: (any AppleTokenVerifier)? {
        get { storage[AppleVerifierKey.self] ?? defaultAppleVerifier }
        set { storage[AppleVerifierKey.self] = newValue }
    }

    private var defaultAppleVerifier: (any AppleTokenVerifier)? {
        guard let team = Environment.get("APPLE_TEAM_ID"),
              let keyID = Environment.get("APPLE_KEY_ID"),
              let privateKey = Environment.get("APPLE_PRIVATE_KEY"),
              let bundleID = Environment.get("APPLE_BUNDLE_ID")
        else { return nil }
        _ = (team, keyID, privateKey)
        return RemoteAppleTokenVerifier(
            jwksURL: URL(string: "https://appleid.apple.com/auth/keys")!,
            audience: bundleID
        )
    }

    var importService: ImportService {
        get { storage[ImportServiceKey.self] ?? defaultImportService }
        set { storage[ImportServiceKey.self] = newValue }
    }

    private var defaultImportService: ImportService {
        ImportService(
            db: db,
            fetcher: SafePageFetcher(),
            extractor: OpenRouterRecipeExtractor(
                apiKey: Environment.get("OPENROUTER_API_KEY") ?? "",
                model: Environment.get("OPENROUTER_MODEL") ?? "openai/gpt-5-mini"
            ),
            imageStorage: SpacesImageStorage(
                endpoint: URL(string: Environment.get("SPACES_ENDPOINT") ?? "https://fra1.digitaloceanspaces.com")!,
                bucket: Environment.get("SPACES_BUCKET") ?? "mealplanner-images",
                region: Environment.get("SPACES_REGION") ?? "fra1"
            )
        )
    }
}

enum EmailSenderKey: StorageKey { typealias Value = any EmailSender }
enum AppleVerifierKey: StorageKey { typealias Value = any AppleTokenVerifier }
enum ImportServiceKey: StorageKey { typealias Value = ImportService }

public func configure(_ app: Application) async throws {
    app.http.server.configuration.hostname = Environment.get("HOSTNAME") ?? "0.0.0.0"
    app.http.server.configuration.port = Int(Environment.get("PORT") ?? "") ?? 8080

    app.middleware.use(RequestIDMiddleware())
    app.middleware.use(ErrorMiddleware())
    app.middleware.use(BearerAuthenticator())
    app.middleware.use(AdminSessionAuthenticator())
    app.middleware.use(CORSMiddleware(configuration: .init(
        allowedOrigin: .originBased,
        allowedMethods: [.GET, .POST, .PATCH, .PUT, .DELETE, .OPTIONS],
        allowedHeaders: ["Content-Type", "Authorization", "X-Request-ID", "X-Client", "X-CSRF-Token"],
        allowCredentials: true
    )))

    let jwtSecret = Environment.get("JWT_SECRET") ?? "development-only-secret-change-me"
    app.jwtManager = await JWTManager(secret: jwtSecret)

    if let url = Environment.get("DATABASE_URL") {
        app.databases.use(try .postgres(url: url), as: .psql)
    } else if app.environment == .testing {
        let host = Environment.get("POSTGRES_HOST") ?? "localhost"
        let port = Environment.get("POSTGRES_PORT") ?? "5432"
        let user = Environment.get("POSTGRES_USER") ?? "mealplanner"
        let password = Environment.get("POSTGRES_PASSWORD") ?? "mealplanner"
        let database = Environment.get("POSTGRES_DB") ?? "mealplanner_test"
        app.databases.use(
            try .postgres(
                url: "postgres://\(user):\(password)@\(host):\(port)/\(database)"
            ),
            as: .psql
        )
    }

    app.migrations.add(CreateUsers())
    app.migrations.add(CreateUserDevices())
    app.migrations.add(CreateMagicLinkTokens())
    app.migrations.add(CreateRefreshTokens())
    app.migrations.add(CreateAdminSessions())
    app.migrations.add(CreateFriendTables())
    app.migrations.add(CreateRecipes())
    app.migrations.add(CreateImportJobs())
    app.migrations.add(CreatePlanningTables())
    app.migrations.add(CreateAuditLogs())

    try await registerRoutes(app)

    if app.environment != .testing {
        try await app.autoMigrate()
    }
}
