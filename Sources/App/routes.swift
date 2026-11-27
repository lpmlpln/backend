import Vapor

/// Identifies exactly which revision is answering requests. Vercel injects
/// `VERCEL_GIT_COMMIT_SHA`; other hosts can set `GIT_COMMIT_SHA`.
func deploymentRevision() -> String {
    Environment.get("VERCEL_GIT_COMMIT_SHA")
        ?? Environment.get("GIT_COMMIT_SHA")
        ?? "local"
}

func registerRoutes(_ app: Application) async throws {
    app.get("health") { _ -> [String: String] in
        ["status": "ok", "revision": deploymentRevision()]
    }
    app.get("health", "ready") { _ -> [String: String] in
        ["status": "ready", "revision": deploymentRevision()]
    }

    // Well-known Apple app site association is served statically in production.
    app.get(".well-known", "apple-app-site-association") { request in
        let team = Environment.get("APPLE_TEAM_ID") ?? "TEAMID"
        let bundle = Environment.get("APPLE_BUNDLE_ID") ?? "com.example.mealplanner"
        let json = """
        {"applinks":{"apps":[],"details":[{"appID":"\(team).\(bundle)","paths":["/auth/verify","/share/*"]}]}}
        """
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(string: json)
        )
    }

    let auth = AuthController()
    auth.register(routes: app.routes)
    RecipeController().register(routes: app.routes)
    PlanController().register(routes: app.routes)
    FriendController().register(routes: app.routes)
    SyncController().register(routes: app.routes)
    AdminController().register(routes: app.routes)

    app.get("admin", "static", ":file") { request -> Response in
        guard let file = request.parameters.get("file") else { throw Abort(.notFound) }
        switch file {
        case "htmx.min.js":
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/javascript"],
                body: .init(string: "/* htmx is vendored in production builds. */")
            )
        case "admin.css":
            return Response(
                status: .ok,
                headers: ["Content-Type": "text/css"],
                body: .init(string: "body{font-family:system-ui;margin:2rem}table{border-collapse:collapse}td,th{padding:.4rem;border:1px solid #ccc}.error{color:#b00}")
            )
        default:
            throw Abort(.notFound)
        }
    }
}
