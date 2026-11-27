import Fluent
import Foundation
import MealPlannerCore
import Vapor

enum AdminSessionKey: StorageKey {
    typealias Value = AdminSessionModel
}

extension Request {
    var adminSession: AdminSessionModel? {
        get { storage[AdminSessionKey.self] }
        set { storage[AdminSessionKey.self] = newValue }
    }

    var adminUserID: UUID? {
        adminSession?.$user.id
    }

    func requireAdmin() throws -> UUID {
        guard let session = adminSession, session.expiresAt > Date() else {
            throw Abort(.unauthorized)
        }
        return session.$user.id
    }
}

struct AdminSessionAuthenticator: AsyncRequestAuthenticator {
    func authenticate(request: Request) async throws {
        guard let token = request.cookies["mp_admin"]?.string else { return }
        let hash = TokenHasher.sha256(token)
        guard let session = try await AdminSessionModel.query(on: request.db)
            .filter(\.$sessionTokenHash == hash)
            .filter(\.$expiresAt > Date())
            .first()
        else { return }
        session.lastSeenAt = Date()
        try? await session.save(on: request.db)
        request.adminSession = session
    }
}

struct AdminController: Sendable {
    func register(routes: some RoutesBuilder) {
        routes.get("admin", "login", use: loginPage)
        routes.post("admin", "login", use: startLogin)
        routes.get("admin", "verify", use: verifyLogin)
        routes.post("admin", "logout", use: logout)
        routes.get("admin", use: dashboard)
        routes.get("admin", "users", use: users)
        routes.get("admin", "users", "new", use: newUser)
        routes.post("admin", "users", use: createUser)
        routes.post("admin", "users", ":userID", "disable", use: disableUser)
        routes.post("admin", "users", ":userID", "admin", use: grantAdmin)
        routes.get("admin", "recipes", use: recipes)
        routes.get("admin", "recipes", "new", use: newRecipe)
        routes.post("admin", "recipes", use: createRecipe)
        routes.get("admin", "recipes", ":recipeID", "edit", use: editRecipe)
        routes.post("admin", "recipes", ":recipeID", use: updateRecipe)
        routes.post("admin", "recipes", ":recipeID", "delete", use: deleteRecipe)
        routes.get("admin", "imports", use: imports)
        routes.get("admin", "imports", "new", use: newImport)
        routes.post("admin", "imports", use: createImport)
        routes.post("admin", "imports", ":jobID", "retry", use: retryImport)
        routes.post("admin", "imports", ":jobID", "run", use: runImport)
        routes.get("admin", "audit", use: audit)
    }

    func page(_ title: String, _ content: String) -> Response {
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title) · MealPlanner Admin</title>
        <script src="/admin/static/htmx.min.js"></script>
        <link rel="stylesheet" href="/admin/static/admin.css"></head>
        <body><nav><a href="/admin">Dashboard</a> · <a href="/admin/users">Users</a> ·
        <a href="/admin/recipes">Recipes</a> ·
        <a href="/admin/imports">Imports</a> · <a href="/admin/audit">Audit</a></nav>
        <main><h1>\(title)</h1>\(content)</main></body></html>
        """
        return Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8"], body: .init(string: html))
    }

    func form(action: String, csrf: String, button: String, extra: String = "") -> String {
        """
        <form method="post" action="\(action)">
        <input type="hidden" name="csrf" value="\(csrf)">
        \(extra)<button type="submit">\(button)</button></form>
        """
    }

    func csrf(_ request: Request) -> String {
        TokenHasher.sha256(request.cookies["mp_admin"]?.string ?? "anonymous")
    }

    func validateCSRF(_ request: Request) throws {
        let cookie = request.cookies["mp_admin"]?.string ?? "anonymous"
        let supplied = request.headers.first(name: "X-CSRF-Token")
            ?? (try? request.content.get(String.self, at: "csrf"))
        guard let supplied, supplied == TokenHasher.sha256(cookie) else {
            throw Abort(.forbidden, reason: "Invalid CSRF token.")
        }
    }

    @Sendable
    func loginPage(_ request: Request) async throws -> Response {
        let message = request.query[String.self, at: "error"].map { "<p class='error'>\($0)</p>" } ?? ""
        return page("Sign in", message + form(action: "/admin/login", csrf: "none", button: "Send magic link", extra: "<input type='email' name='email' required>"))
    }

    @Sendable
    func startLogin(_ request: Request) async throws -> Response {
        struct LoginBody: Content { var email: String }
        let email = request.query[String.self, at: "email"]
            ?? (try? request.content.decode(LoginBody.self).email)
            ?? ""
        guard email.contains("@") else {
            return page("Sign in", "<p class='error'>Enter a valid email.</p>")
        }

        let service = AuthService(
            db: request.db,
            emailSender: request.application.emailSender,
            baseURL: request.application.appBaseURL,
            jwt: request.application.jwtManager!,
            accessTTL: request.application.accessTTL,
            refreshTTLDays: request.application.refreshTTLDays,
            magicLinkTTLSeconds: request.application.magicLinkTTL
        )
        try await service.startMagicLink(
            email: email,
            client: "admin",
            requestIP: request.remoteAddress?.ipAddress,
            userAgent: request.headers.first(name: .userAgent),
            logger: request.logger
        )
        return page("Check your email", "<p>A sign-in link was sent to \(email).</p>")
    }

    @Sendable
    func verifyLogin(_ request: Request) async throws -> Response {
        guard let token = request.query[String.self, at: "token"],
              let email = request.query[String.self, at: "email"]
        else { throw Abort(.badRequest) }

        let hash = TokenHasher.sha256(token)
        guard let record = try await MagicLinkTokenModel.query(on: request.db)
            .filter(\.$tokenHash == hash)
            .first(),
            record.email == email, record.client == "admin", record.consumedAt == nil,
            record.expiresAt > Date()
        else { throw Abort(.unauthorized) }

        guard let user = try await UserModel.query(on: request.db).filter(\.$email == email).first(),
              user.isAdmin, !user.isDisabled
        else { throw Abort(.forbidden) }

        record.consumedAt = Date()
        record.$user.id = user.id
        try await record.save(on: request.db)

        let sessionToken = TokenHasher.randomURLSafe()
        let session = AdminSessionModel(
            userID: try user.requireID(),
            sessionTokenHash: TokenHasher.sha256(sessionToken),
            expiresAt: Date().addingTimeInterval(8 * 3_600)
        )
        try await session.save(on: request.db)

        let response = Response(status: .found, headers: ["Location": "/admin"], body: .empty)
        response.cookies["mp_admin"] = HTTPCookies.Value(
            string: sessionToken,
            expires: Date().addingTimeInterval(8 * 3_600),
            maxAge: 8 * 3_600,
            path: "/",
            isSecure: request.application.environment == .production,
            isHTTPOnly: true,
            sameSite: .lax
        )
        return response
    }

    @Sendable
    func logout(_ request: Request) async throws -> Response {
        if let token = request.cookies["mp_admin"]?.string {
            let hash = TokenHasher.sha256(token)
            if let session = try await AdminSessionModel.query(on: request.db)
                .filter(\.$sessionTokenHash == hash).first() {
                try await session.delete(on: request.db)
            }
        }
        let response = Response(status: .found, headers: ["Location": "/admin/login"], body: .empty)
        response.cookies["mp_admin"] = .expired
        return response
    }

    @Sendable
    func dashboard(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        let users = try await UserModel.query(on: request.db).all().count
        let recipes = try await RecipeModel.query(on: request.db).all().count
        let jobs = try await ImportJobModel.query(on: request.db).filter(\.$status == "failed").all().count
        return page("Dashboard", """
        <ul><li>Users: \(users)</li><li>Recipes: \(recipes)</li><li>Failed imports: \(jobs)</li></ul>
        """ + form(action: "/admin/logout", csrf: csrf(request), button: "Sign out"))
    }

    @Sendable
    func users(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        let users = try await UserModel.query(on: request.db).sort(\.$email).all()
        var rows = ""
        for user in users {
            let id = user.id?.uuidString ?? ""
            rows += """
            <tr><td>\(user.email)</td><td>\(user.displayName)</td>
            <td>\(user.isAdmin ? "admin" : "user")</td><td>\(user.isDisabled ? "disabled" : "active")</td>
            <td>\(form(action: "/admin/users/\(id)/disable", csrf: csrf(request), button: user.isDisabled ? "Enable" : "Disable"))</td>
            <td>\(form(action: "/admin/users/\(id)/admin", csrf: csrf(request), button: user.isAdmin ? "Revoke admin" : "Grant admin"))</td></tr>
            """
        }
        let newUserLink = "<p><a href='/admin/users/new'>New user</a></p>"
        return page("Users", newUserLink + "<table><tr><th>Email</th><th>Name</th><th>Role</th><th>Status</th><th></th><th></th></tr>\(rows)</table>")
    }

    @Sendable
    func disableUser(_ request: Request) async throws -> Response {
        let actor = try request.requireAdmin()
        try validateCSRF(request)
        guard let id = request.parameters.get("userID", as: UUID.self),
              let user = try await UserModel.find(id, on: request.db) else { throw Abort(.notFound) }
        user.isDisabled.toggle()
        try await user.save(on: request.db)
        try await AuditLogModel(actorUserID: actor, action: "admin.user.disable", entityType: "user", entityID: id).save(on: request.db)
        return Response(status: .found, headers: ["Location": "/admin/users"], body: .empty)
    }

    @Sendable
    func grantAdmin(_ request: Request) async throws -> Response {
        let actor = try request.requireAdmin()
        try validateCSRF(request)
        guard let id = request.parameters.get("userID", as: UUID.self),
              let user = try await UserModel.find(id, on: request.db) else { throw Abort(.notFound) }
        user.isAdmin.toggle()
        try await user.save(on: request.db)
        try await AuditLogModel(actorUserID: actor, action: "admin.user.role", entityType: "user", entityID: id).save(on: request.db)
        return Response(status: .found, headers: ["Location": "/admin/users"], body: .empty)
    }

    @Sendable
    func imports(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        let jobs = try await ImportJobModel.query(on: request.db).sort(\.$createdAt, .descending).all()
        var rows = ""
        for job in jobs {
            let id = job.id?.uuidString ?? ""
            rows += """
            <tr><td>\(job.url)</td><td>\(job.status)</td><td>\(job.attempts)</td>
            <td>\(job.errorMessage ?? "")</td>
            <td>\(job.status == "queued"
                ? form(action: "/admin/imports/\(id)/run", csrf: csrf(request), button: "Run")
                : form(action: "/admin/imports/\(id)/retry", csrf: csrf(request), button: "Retry"))</td></tr>
            """
        }
        let newImportLink = "<p><a href='/admin/imports/new'>New import</a></p>"
        return page("Imports", newImportLink + "<table><tr><th>URL</th><th>Status</th><th>Attempts</th><th>Error</th><th></th></tr>\(rows)</table>")
    }

    @Sendable
    func runImport(_ request: Request) async throws -> Response {
        try await processImport(request, action: "admin.import.run", heading: "Import started", requireQueued: true)
    }

    @Sendable
    func retryImport(_ request: Request) async throws -> Response {
        try await processImport(request, action: "admin.import.retry", heading: "Import retried", requireQueued: false)
    }

    private func processImport(
        _ request: Request,
        action: String,
        heading: String,
        requireQueued: Bool
    ) async throws -> Response {
        let actor = try request.requireAdmin()
        try validateCSRF(request)
        guard let id = request.parameters.get("jobID", as: UUID.self) else { throw Abort(.notFound) }

        if requireQueued {
            guard let job = try await ImportJobModel.find(id, on: request.db), job.status == "queued" else {
                throw Abort(.badRequest, reason: "Only queued imports can be started.")
            }
        }

        let result = try await request.application.importService.process(jobID: id)
        try await AuditLogModel(
            actorUserID: actor,
            action: action,
            entityType: "import_job",
            entityID: id
        ).save(on: request.db)
        return page(heading, "<p>Status: \(result.status.rawValue)</p><a href='/admin/imports'>Back</a>")
    }

    @Sendable
    func audit(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        let entries = try await AuditLogModel.query(on: request.db).sort(\.$createdAt, .descending).limit(100).all()
        var rows = ""
        for entry in entries {
            rows += "<tr><td>\(entry.createdAt ?? Date())</td><td>\(entry.action)</td><td>\(entry.entityType)</td><td>\(entry.entityID?.uuidString ?? "")</td></tr>"
        }
        return page("Audit log", "<table><tr><th>Time</th><th>Action</th><th>Entity</th><th>ID</th></tr>\(rows)</table>")
    }
}
