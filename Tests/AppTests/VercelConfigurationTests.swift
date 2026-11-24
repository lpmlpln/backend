import Foundation
import Testing
import Vapor
@testable import App

@Suite(.serialized)
struct VercelConfigurationTests {
    @Test("Vercel deployments require a PostgreSQL DATABASE_URL")
    func requiresDatabaseURL() async throws {
        try await testGate.run(TestBody {
            let app = try await Application.make(Environment(name: "testing", arguments: ["App"]))
            #expect(throws: AppError.self) {
                try AppDatabase.configure(app, values: ["VERCEL": "1"])
            }
            try await app.asyncShutdown()
        })
    }

    @Test("SQLite is rejected on Vercel")
    func rejectsSQLite() async throws {
        try await testGate.run(TestBody {
            let app = try await Application.make(Environment(name: "testing", arguments: ["App"]))
            #expect(throws: AppError.self) {
                try AppDatabase.configure(app, values: [
                    "VERCEL": "1",
                    "DB_DRIVER": "sqlite",
                    "SQLITE_PATH": ":memory:",
                ])
            }
            #expect(throws: AppError.self) {
                try AppDatabase.configure(app, values: [
                    "VERCEL": "1",
                    "DATABASE_URL": "sqlite::memory:",
                ])
            }
            try await app.asyncShutdown()
        })
    }

    @Test("A PostgreSQL URL is accepted on Vercel")
    func acceptsPostgresURL() async throws {
        try await testGate.run(TestBody {
            let app = try await Application.make(Environment(name: "testing", arguments: ["App"]))
            try AppDatabase.configure(app, values: [
                "VERCEL": "1",
                "DATABASE_URL": "postgres://mealplanner:mealplanner@localhost:5432/mealplanner_test",
            ])
            try await app.asyncShutdown()
        })
    }

    @Test("Vercel Postgres POSTGRES_URL is accepted as a fallback")
    func acceptsVercelPostgresURL() async throws {
        try await testGate.run(TestBody {
            let app = try await Application.make(Environment(name: "testing", arguments: ["App"]))
            try AppDatabase.configure(app, values: [
                "VERCEL": "1",
                "POSTGRES_URL": "postgres://mealplanner:mealplanner@localhost:5432/mealplanner_test",
            ])
            try await app.asyncShutdown()
        })
    }
}
