import Foundation
import MealPlannerCore
import Testing
import Vapor
import XCTVapor
@testable import App

@Suite(.serialized)
struct SQLiteTests {
    @Test("Local development SQLite configuration migrates and serves requests")
    func sqliteDevelopmentFlow() async throws {
        try await testGate.run(TestBody {
            let app = try await makeTestApp(databaseValues: [
                "DB_DRIVER": "sqlite",
                "SQLITE_PATH": ":memory:",
            ])

            try await apiStatus(app, .GET, "/health")

            let user = try await signIn(app, email: "sqlite@example.com")
            let recipe = try await createRecipe(app, token: user, title: "SQLite Soup")
            #expect(recipe.title == "SQLite Soup")

            let plan = try await createPlan(app, token: user, days: 2)
            #expect(plan.entries.count == 2)
            #expect(plan.shoppingList?.items.isEmpty == false)

            let pulled: SyncPullResponse = try await apiRequest(app, .GET, "/sync/pull", headers: authHeaders(user))
            #expect(pulled.plans.contains { $0.planID == plan.id })

            try await app.asyncShutdown()
        })
    }

    @Test("A sqlite: DATABASE_URL selects the SQLite driver")
    func sqliteURLConfiguration() async throws {
        try await testGate.run(TestBody {
            let app = try await makeTestApp(databaseValues: ["DATABASE_URL": "sqlite::memory:"])
            try await apiStatus(app, .GET, "/health")

            let user = try await signIn(app, email: "sqlite-url@example.com")
            #expect(!user.accessToken.isEmpty)

            try await app.asyncShutdown()
        })
    }
}
