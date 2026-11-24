import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import JWTKit
import MealPlannerCore
import SQLKit
import Vapor

extension Application {
    var appBaseURL: String {
        if let url = Environment.get("APP_BASE_URL"), !url.isEmpty { return url }
        // Vercel sets VERCEL_URL for every deployment. Use it so magic links
        // point at the deployed API instead of localhost.
        if let host = Environment.get("VERCEL_URL"), !host.isEmpty {
            return "https://\(host)"
        }
        return "http://localhost:8080"
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
                client: client,
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
            audience: bundleID,
            client: client
        )
    }

    var importService: ImportService {
        get { storage[ImportServiceKey.self] ?? defaultImportService }
        set { storage[ImportServiceKey.self] = newValue }
    }

    private var defaultImportService: ImportService {
        ImportService(
            db: db,
            fetcher: SafePageFetcher(client: client),
            extractor: OpenRouterRecipeExtractor(
                apiKey: Environment.get("OPENROUTER_API_KEY") ?? "",
                model: Environment.get("OPENROUTER_MODEL") ?? "openai/gpt-5-mini",
                client: client
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

/// Database selection for local development, tests and production.
///
/// Resolution order:
/// 1. `DB_DRIVER=sqlite` — SQLite at `SQLITE_PATH` (`:memory:` supported).
/// 2. `DATABASE_URL` (or Vercel's `POSTGRES_URL`) — a `sqlite:` URL selects
///    SQLite, anything else PostgreSQL.
/// 3. Testing environment — PostgreSQL using `POSTGRES_*` variables.
/// 4. Local development — SQLite at `SQLITE_PATH` or `mealplanner.sqlite`.
///
/// `DB_DRIVER` is checked first so it overrides a `DATABASE_URL` from a local
/// `.env` file, which Vapor loads automatically.
///
/// PostgreSQL remains the production database; SQLite is intentionally limited
/// to local development and tests.
enum AppDatabase {
    static func configure(_ app: Application, values: [String: String]) throws {
        let databaseURL = values["DATABASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let vercelPostgresURL = values["POSTGRES_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedURL = [databaseURL, vercelPostgresURL]
            .compactMap { $0 }
            .first { !$0.isEmpty }

        // Vercel functions have an ephemeral filesystem. A local SQLite file
        // would be lost between invocations, so require an external database.
        if values["VERCEL"] == "1",
           values["DB_DRIVER"]?.lowercased() != "sqlite",
           resolvedURL == nil {
            throw AppError.validation(
                "DATABASE_URL (or POSTGRES_URL) must be set to a PostgreSQL connection string on Vercel."
            )
        }

        if values["DB_DRIVER"]?.lowercased() == "sqlite" {
            if values["VERCEL"] == "1" {
                throw AppError.validation(
                    "SQLite cannot be used on Vercel; unset DB_DRIVER and set DATABASE_URL (or POSTGRES_URL) to PostgreSQL."
                )
            }
            app.databases.use(
                .sqlite(sqliteConfiguration(path: values["SQLITE_PATH"]?.trimmingCharacters(in: .whitespaces))),
                as: .sqlite
            )
            return
        }

        if let url = resolvedURL {
            if let configuration = sqliteConfiguration(from: url) {
                if values["VERCEL"] == "1" {
                    throw AppError.validation(
                        "SQLite cannot be used on Vercel; set DATABASE_URL (or POSTGRES_URL) to PostgreSQL."
                    )
                }
                app.databases.use(.sqlite(configuration), as: .sqlite)
            } else {
                app.databases.use(try .postgres(url: url), as: .psql)
            }
            return
        }

        if app.environment == .testing {
            let host = values["POSTGRES_HOST"] ?? "localhost"
            let port = values["POSTGRES_PORT"] ?? "5432"
            let user = values["POSTGRES_USER"] ?? "mealplanner"
            let password = values["POSTGRES_PASSWORD"] ?? "mealplanner"
            let database = values["POSTGRES_DB"] ?? "mealplanner_test"
            app.databases.use(
                try .postgres(url: "postgres://\(user):\(password)@\(host):\(port)/\(database)"),
                as: .psql
            )
            return
        }

        // No explicit configuration in development: use a local SQLite file so
        // `swift run App` works without a PostgreSQL server.
        app.databases.use(
            .sqlite(sqliteConfiguration(path: values["SQLITE_PATH"]?.trimmingCharacters(in: .whitespaces))),
            as: .sqlite
        )
    }

    private static func sqliteConfiguration(from url: String) -> SQLiteConfiguration? {
        guard url.hasPrefix("sqlite:") else { return nil }
        let remainder = String(url.dropFirst("sqlite:".count))

        if remainder.contains(":memory:") || remainder == "//memory" || remainder == "memory" {
            return SQLiteConfiguration(storage: .memory)
        }

        var path = remainder
        if path.hasPrefix("//") { path = String(path.dropFirst(2)) }
        guard !path.isEmpty else { return SQLiteConfiguration(storage: .memory) }
        return SQLiteConfiguration(storage: .file(path: path))
    }

    private static func sqliteConfiguration(path: String?) -> SQLiteConfiguration {
        let value = path ?? "mealplanner.sqlite"
        if value == ":memory:" || value == "memory" {
            return SQLiteConfiguration(storage: .memory)
        }
        return SQLiteConfiguration(storage: .file(path: value))
    }
}

public func configure(_ app: Application, databaseValues: [String: String]? = nil) async throws {
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

    try AppDatabase.configure(app, values: databaseValues ?? ProcessInfo.processInfo.environment)

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

    try await runMigrationsIfNeeded(app)
}

/// Runs migrations (and the initial-admin bootstrap) with a PostgreSQL
/// transaction-scoped advisory lock so concurrent serverless cold starts
/// cannot race on `CREATE TABLE`.
private func runMigrationsIfNeeded(_ app: Application) async throws {
    guard app.environment != .testing else { return }
    guard Environment.get("RUN_MIGRATIONS")?.lowercased() != "false" else { return }

    let isPostgres = (app.db as? any SQLDatabase)?
        .dialect.name.lowercased().contains("postgres") ?? false

    if isPostgres {
        try await app.db.transaction { db in
            guard let sql = db as? any SQLDatabase else {
                throw AppError.server("Could not acquire the migration lock.")
            }
            try await sql.raw("SELECT pg_advisory_xact_lock(724476795)").run()

            let migrator = Migrator(
                databaseFactory: { _ in db },
                migrations: app.migrations,
                on: app.eventLoopGroup.next()
            )
            try await migrator.setupIfNeeded().get()
            try await migrator.prepareBatch().get()

            try await AdminBootstrap.ensureInitialAdmin(
                on: db,
                email: Environment.get("INITIAL_ADMIN_EMAIL"),
                logger: app.logger
            )
        }
    } else {
        try await app.autoMigrate()
        try await AdminBootstrap.ensureInitialAdmin(
            on: app.db,
            email: Environment.get("INITIAL_ADMIN_EMAIL"),
            logger: app.logger
        )
    }
}
