import Fluent
import Foundation
import MealPlannerCore
import Testing
import Vapor
import XCTVapor
@testable import App

@Suite(.serialized)
struct AdminPagesTests {
    private func csrf(_ cookie: String) -> String {
        let value = cookie.split(separator: "=", maxSplits: 1).dropFirst().joined(separator: "=")
        return TokenHasher.sha256(value)
    }

    private func headers(_ cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "Content-Type": "application/json",
            "X-CSRF-Token": csrf(cookie),
        ]
    }

    @Test("Admin can create a user from the admin page")
    func createUser() async throws {
        try await testGate.run(TestBody {
            let app = try await makeTestApp()
            try await resetDatabase(app)
            _ = try await makeAdmin(app: app)
            let cookie = try await adminCookie(app, email: "admin@example.com")

            let createForm: XCTHTTPResponse = try await apiResponse(app, .GET, "/admin/users/new", headers: ["Cookie": cookie])
            #expect(createForm.body.string.contains("Create user"))

            struct Body: Encodable {
                var email: String
                var displayName: String
                var isAdmin = false
                var csrf: String
            }
            try await apiStatus(
                app, .POST, "/admin/users",
                headers: headers(cookie),
                body: Body(email: "new@example.com", displayName: "New User", csrf: csrf(cookie)),
                expected: .found
            )

            let user = try await UserModel.query(on: app.db)
                .filter(\.$email == "new@example.com")
                .first()
            #expect(user?.displayName == "New User")
            #expect(user?.isAdmin == false)

            let list: XCTHTTPResponse = try await apiResponse(app, .GET, "/admin/users", headers: ["Cookie": cookie])
            #expect(list.body.string.contains("new@example.com"))

            try await app.asyncShutdown()
        })
    }

    @Test("Admin can create, update and delete recipes")
    func recipeCRUD() async throws {
        try await testGate.run(TestBody {
            let app = try await makeTestApp()
            try await resetDatabase(app)
            _ = try await makeAdmin(app: app)
            let cookie = try await adminCookie(app, email: "admin@example.com")

            struct Body: Encodable {
                var title: String
                var servings = 2
                var visibility: String
                var instructions: String
                var ingredients: String
                var csrf: String
                var dietaryTags: String = "vegan"
                var cuisine: String = "Test"
                var dishType: String = "Soup"
                var mainIngredient: String = "Carrot"
            }

            let newForm: XCTHTTPResponse = try await apiResponse(app, .GET, "/admin/recipes/new", headers: ["Cookie": cookie])
            #expect(newForm.body.string.contains("Create recipe"))

            try await apiStatus(
                app, .POST, "/admin/recipes",
                headers: headers(cookie),
                body: Body(
                    title: "Admin Soup",
                    visibility: "public",
                    instructions: "Chop\nSimmer",
                    ingredients: "Carrot | 2 | piece | produce |",
                    csrf: csrf(cookie)
                ),
                expected: .found
            )

            let created = try await RecipeModel.query(on: app.db)
                .filter(\.$title == "Admin Soup")
                .first()
            let recipeID = try created?.requireID()
            #expect(recipeID != nil)
            let ingredients = try await RecipeIngredientModel.query(on: app.db)
                .filter(\.$recipe.$id == recipeID!)
                .all()
            #expect(ingredients.count == 1)
            #expect(ingredients[0].name == "Carrot")

            let editForm: XCTHTTPResponse = try await apiResponse(
                app, .GET, "/admin/recipes/\(recipeID!.uuidString)/edit", headers: ["Cookie": cookie]
            )
            #expect(editForm.body.string.contains("Admin Soup"))

            try await apiStatus(
                app, .POST, "/admin/recipes/\(recipeID!.uuidString)",
                headers: headers(cookie),
                body: Body(
                    title: "Updated Soup",
                    visibility: "private",
                    instructions: "Simmer",
                    ingredients: "Carrot | 3 | piece | produce |",
                    csrf: csrf(cookie)
                ),
                expected: .found
            )
            let updated = try await RecipeModel.find(recipeID!, on: app.db)
            #expect(updated?.title == "Updated Soup")
            #expect(updated?.visibility == "private")

            try await apiStatus(
                app, .POST, "/admin/recipes/\(recipeID!.uuidString)/delete",
                headers: headers(cookie),
                expected: .found
            )
            let deleted = try await RecipeModel.query(on: app.db)
                .filter(\.$id == recipeID!)
                .withDeleted()
                .first()
            #expect(deleted?.deletedAt != nil)

            let audit = try await AuditLogModel.query(on: app.db)
                .filter(\.$action ~~ ["admin.recipe.create", "admin.recipe.update", "admin.recipe.delete"])
                .all()
            #expect(audit.count == 3)

            try await app.asyncShutdown()
        })
    }

    @Test("Admin can create an import job")
    func createImport() async throws {
        try await testGate.run(TestBody {
            let app = try await makeTestApp()
            try await resetDatabase(app)
            _ = try await makeAdmin(app: app)
            let cookie = try await adminCookie(app, email: "admin@example.com")
            app.importService = ImportService(
                db: app.db,
                fetcher: FakeFetcher(),
                extractor: FakeExtractor(),
                imageStorage: FakeImageStorage()
            )

            let newForm: XCTHTTPResponse = try await apiResponse(app, .GET, "/admin/imports/new", headers: ["Cookie": cookie])
            #expect(newForm.body.string.contains("Create import"))

            struct Body: Encodable {
                var url: String
                var csrf: String
            }
            let created: XCTHTTPResponse = try await apiResponse(
                app, .POST, "/admin/imports",
                headers: headers(cookie),
                body: Body(url: "https://example.com/recipes/admin-soup", csrf: csrf(cookie))
            )
            #expect(created.body.string.contains("Import Created"))

            let jobs = try await ImportJobModel.query(on: app.db).all()
            #expect(jobs.count == 1)
            #expect(jobs[0].status == "queued")

            let audit = try await AuditLogModel.query(on: app.db)
                .filter(\.$action == "admin.import.create")
                .first()
            #expect(audit != nil)

            try await app.asyncShutdown()
        })
    }

    @Test("Admin can run a queued import from the imports page")
    func runQueuedImport() async throws {
        try await testGate.run(TestBody {
            let app = try await makeTestApp()
            try await resetDatabase(app)
            _ = try await makeAdmin(app: app)
            let cookie = try await adminCookie(app, email: "admin@example.com")
            app.importService = ImportService(
                db: app.db,
                fetcher: FakeFetcher(),
                extractor: FakeExtractor(),
                imageStorage: FakeImageStorage()
            )

            struct CreateBody: Encodable {
                var url: String
                var csrf: String
            }
            try await apiResponse(
                app, .POST, "/admin/imports",
                headers: headers(cookie),
                body: CreateBody(url: "https://example.com/recipes/run-now", csrf: csrf(cookie))
            )

            let jobs = try await ImportJobModel.query(on: app.db).all()
            let jobID = try jobs[0].requireID()

            let list: XCTHTTPResponse = try await apiResponse(app, .GET, "/admin/imports", headers: ["Cookie": cookie])
            #expect(list.body.string.contains("Run"))

            let result: XCTHTTPResponse = try await apiResponse(
                app, .POST, "/admin/imports/\(jobID.uuidString)/run",
                headers: headers(cookie)
            )
            #expect(result.body.string.contains("Import started"))

            let updated = try await ImportJobModel.find(jobID, on: app.db)
            #expect(updated?.status == "completed")

            let audit = try await AuditLogModel.query(on: app.db)
                .filter(\.$action == "admin.import.run")
                .first()
            #expect(audit != nil)

            try await app.asyncShutdown()
        })
    }

    @Test("Admin POST actions require CSRF")
    func csrfEnforced() async throws {
        try await testGate.run(TestBody {
            let app = try await makeTestApp()
            try await resetDatabase(app)
            _ = try await makeAdmin(app: app)
            let cookie = try await adminCookie(app, email: "admin@example.com")

            struct Body: Encodable {
                var email = "spoof@example.com"
                var displayName = "Spoof"
                var csrf = "wrong"
            }
            try await apiStatus(
                app, .POST, "/admin/users",
                headers: ["Cookie": cookie, "Content-Type": "application/json"],
                body: Body(),
                expected: .forbidden
            )

            try await app.asyncShutdown()
        })
    }
}
