import Fluent
import Foundation
import Vapor

/// Creates or promotes an initial administrator from `INITIAL_ADMIN_EMAIL`.
///
/// Runs once at startup after migrations. If any active admin already exists,
/// the variable is ignored so it cannot accidentally overwrite an existing
/// production admin.
enum AdminBootstrap {
    static func ensureInitialAdmin(
        on db: any Database,
        email rawEmail: String?,
        logger: Logger
    ) async throws {
        let trimmed = rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        guard trimmed.contains("@"), trimmed.count <= 320 else {
            logger.warning("INITIAL_ADMIN_EMAIL is not a valid email address; ignoring it.")
            return
        }

        let email = trimmed.lowercased()

        let existingAdmin = try await UserModel.query(on: db)
            .filter(\.$isAdmin == true)
            .filter(\.$isDisabled == false)
            .first()
        if existingAdmin != nil {
            logger.info("An admin already exists; ignoring INITIAL_ADMIN_EMAIL.")
            return
        }

        if let user = try await UserModel.query(on: db).filter(\.$email == email).first() {
            user.isAdmin = true
            if user.isDisabled {
                user.isDisabled = false
            }
            try await user.save(on: db)
            logger.notice("Promoted existing user \(email) to admin via INITIAL_ADMIN_EMAIL.")
        } else {
            let name = String(email.split(separator: "@").first ?? "Admin")
            let user = UserModel(email: email, displayName: name, isAdmin: true)
            try await user.save(on: db)
            logger.notice("Created initial admin \(email) via INITIAL_ADMIN_EMAIL.")
        }
    }
}
