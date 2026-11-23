import Fluent
import Foundation
import MealPlannerCore
import Testing
import Vapor
import XCTVapor
@testable import App

@Suite(.serialized)
struct AdminBootstrapTests {
    private func app() async throws -> Application {
        try await makeTestApp(databaseValues: ["DB_DRIVER": "sqlite", "SQLITE_PATH": ":memory:"])
    }

    @Test("Creates the initial admin when none exists")
    func createsAdmin() async throws {
        try await testGate.run(TestBody {
            let app = try await app()
            try await AdminBootstrap.ensureInitialAdmin(
                on: app.db,
                email: "admin@example.com",
                logger: app.logger
            )

            let admin = try await UserModel.query(on: app.db)
                .filter(\.$email == "admin@example.com")
                .first()
            #expect(admin?.isAdmin == true)
            #expect(admin?.displayName == "admin")

            try await app.asyncShutdown()
        })
    }

    @Test("Promotes an existing user")
    func promotesExistingUser() async throws {
        try await testGate.run(TestBody {
            let app = try await app()
            let user = UserModel(email: "owner@example.com", displayName: "Owner")
            try await user.save(on: app.db)

            try await AdminBootstrap.ensureInitialAdmin(
                on: app.db,
                email: "owner@example.com",
                logger: app.logger
            )

            let updated = try await UserModel.query(on: app.db)
                .filter(\.$email == "owner@example.com")
                .first()
            #expect(updated?.isAdmin == true)
            let count = try await UserModel.query(on: app.db).all().count
            #expect(count == 1)

            try await app.asyncShutdown()
        })
    }

    @Test("Ignores the variable when an admin already exists")
    func ignoresWhenAdminExists() async throws {
        try await testGate.run(TestBody {
            let app = try await app()
            let existing = UserModel(email: "existing@example.com", displayName: "Existing", isAdmin: true)
            try await existing.save(on: app.db)

            try await AdminBootstrap.ensureInitialAdmin(
                on: app.db,
                email: "new-admin@example.com",
                logger: app.logger
            )

            let target = try await UserModel.query(on: app.db)
                .filter(\.$email == "new-admin@example.com")
                .first()
            #expect(target == nil)
            let count = try await UserModel.query(on: app.db).all().count
            #expect(count == 1)

            try await app.asyncShutdown()
        })
    }

    @Test("Ignores a disabled admin and re-enables the configured user")
    func disabledAdminCase() async throws {
        try await testGate.run(TestBody {
            let app = try await app()
            let disabled = UserModel(
                email: "old@example.com",
                displayName: "Old",
                isAdmin: true,
                isDisabled: true
            )
            try await disabled.save(on: app.db)
            let target = UserModel(email: "new@example.com", displayName: "New")
            try await target.save(on: app.db)

            try await AdminBootstrap.ensureInitialAdmin(
                on: app.db,
                email: "new@example.com",
                logger: app.logger
            )

            let updated = try await UserModel.query(on: app.db)
                .filter(\.$email == "new@example.com")
                .first()
            #expect(updated?.isAdmin == true)

            try await app.asyncShutdown()
        })
    }

    @Test("Invalid or empty values are ignored")
    func invalidValues() async throws {
        try await testGate.run(TestBody {
            let app = try await app()
            try await AdminBootstrap.ensureInitialAdmin(on: app.db, email: "  ", logger: app.logger)
            try await AdminBootstrap.ensureInitialAdmin(on: app.db, email: "not-an-email", logger: app.logger)

            let count = try await UserModel.query(on: app.db).all().count
            #expect(count == 0)

            try await app.asyncShutdown()
        })
    }
}
