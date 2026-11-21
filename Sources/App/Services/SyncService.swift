import Fluent
import Foundation
import MealPlannerCore
import Vapor

struct SyncService: Sendable {
    let db: any Database
    let access: AccessPolicy
    let planning: PlanningService

    // MARK: - Pull

    func pull(userID: UUID, cursor: String?) async throws -> SyncPullResponse {
        let since = cursor.flatMap(ISO8601DateFormatter().date(from:)) ?? Date(timeIntervalSince1970: 0)
        let now = Date()

        // Recipes: accessible recipes changed since the cursor.
        var recipePayloads: [SyncRecipePayload] = []
        for recipe in try await RecipeModel.query(on: db)
            .filter(\.$deletedAt == nil)
            .all() {
            guard let updated = recipe.updatedAt, updated > since else { continue }
            guard try await access.canView(recipe: recipe, userID: userID) else { continue }
            recipePayloads.append(
                SyncRecipePayload(recipe: try await planning.dto(for: recipe, userID: userID))
            )
        }

        // Plan documents and revocations.
        let memberships = try await PlanMemberModel.query(on: db)
            .filter(\.$user.$id == userID)
            .all()
        var planPayloads: [SyncPlanPayload] = []
        var shoppingPayloads: [SyncShoppingPayload] = []

        for membership in memberships {
            let planID = membership.$plan.id
            let changed = (membership.updatedAt ?? Date()) > since
            guard changed else { continue }

            if membership.revokedAt != nil {
                if let document = try await PlanDocumentModel.find(planID, on: db) {
                    planPayloads.append(
                        SyncPlanPayload(planID: planID, state: document.state, revoked: true)
                    )
                }
                if let shopping = try await ShoppingListDocumentModel.find(planID, on: db) {
                    shoppingPayloads.append(
                        SyncShoppingPayload(planID: planID, state: shopping.state, revoked: true)
                    )
                }
                continue
            }

            if let document = try await PlanDocumentModel.find(planID, on: db) {
                planPayloads.append(SyncPlanPayload(planID: planID, state: document.state))
            }
            if let shopping = try await ShoppingListDocumentModel.find(planID, on: db) {
                shoppingPayloads.append(SyncShoppingPayload(planID: planID, state: shopping.state))
            }
        }

        // Friends.
        var friendPayloads: [SyncFriendPayload] = []
        let outgoing = try await FriendRequestModel.query(on: db)
            .filter(\.$fromUser.$id == userID).all()
        let incoming = try await FriendRequestModel.query(on: db)
            .filter(\.$toUser.$id == userID).all()
        let requests = outgoing + incoming.filter { $0.$fromUser.id != userID }
        for request in requests {
            let otherID = request.$fromUser.id == userID ? request.$toUser.id : request.$fromUser.id
            guard let other = try await UserModel.find(otherID, on: db) else { continue }
            let status: FriendStatus
            switch request.status {
            case "accepted": status = .accepted
            case "pending":
                status = request.$fromUser.id == userID ? .pendingOutgoing : .pendingIncoming
            default: continue
            }
            friendPayloads.append(
                SyncFriendPayload(
                    friend: FriendDTO(
                        userID: otherID,
                        displayName: other.displayName,
                        email: other.email,
                        status: status,
                        requestedAt: request.createdAt ?? Date()
                    )
                )
            )
        }

        let cursorValue = ISO8601DateFormatter().string(from: now)
        return SyncPullResponse(
            recipes: recipePayloads,
            plans: planPayloads,
            shoppingLists: shoppingPayloads,
            friends: friendPayloads,
            cursor: SyncCursor(value: cursorValue, serverTime: now),
            serverTime: now
        )
    }

    // MARK: - Push

    func push(userID: UUID, request: SyncPushRequest) async throws -> SyncPushResponse {
        var rejections: [SyncRejection] = []
        var warnings: [SyncWarning] = []
        var responsePlans: [SyncPlanPayload] = []
        var responseShopping: [SyncShoppingPayload] = []

        for payload in request.plans {
            guard payload.schemaVersion == 1 else {
                rejections.append(SyncRejection(
                    planID: payload.planID,
                    code: .syncInvalidState,
                    message: "Unsupported plan schema version."
                ))
                continue
            }

            guard let role = try await access.role(for: payload.planID, userID: userID) else {
                rejections.append(SyncRejection(
                    planID: payload.planID,
                    code: .planAccessRevoked,
                    message: "You no longer have access to this plan."
                ))
                continue
            }
            guard role.canEdit else {
                rejections.append(SyncRejection(
                    planID: payload.planID,
                    code: .planRoleInsufficient,
                    message: "Viewers cannot push changes."
                ))
                continue
            }

            guard let stored = try await PlanDocumentModel.find(payload.planID, on: db) else {
                rejections.append(SyncRejection(
                    planID: payload.planID,
                    code: .notFound,
                    message: "Plan not found."
                ))
                continue
            }

            if role != .owner,
               let rejection = protectedFieldRejection(
                   incoming: payload.state,
                   stored: stored.state,
                   planID: payload.planID
               ) {
                rejections.append(rejection)
                continue
            }

            let merged = stored.state.merged(with: payload.state)
            stored.state = merged
            stored.stateHash = merged.stateHash
            stored.schemaVersion = merged.schemaVersion
            stored.updatedAt = Date()
            try await stored.save(on: db)

            if let plan = try await MealPlanModel.find(payload.planID, on: db) {
                plan.lastSyncedByUserID = userID
                plan.lastSyncedAt = Date()
                plan.updatedAt = Date()
                try await plan.save(on: db)
            }

            for entry in merged.materializedEntries() {
                let accessible = try await RecipeModel.find(entry.recipeID, on: db)
                if accessible == nil || accessible?.deletedAt != nil {
                    warnings.append(
                        SyncWarning(
                            planID: payload.planID,
                            entryKey: entry.key.rawValue,
                            recipeID: entry.recipeID,
                            message: "Recipe unavailable. Replace this meal."
                        )
                    )
                }
            }

            responsePlans.append(SyncPlanPayload(planID: payload.planID, state: merged))
        }

        for payload in request.shoppingLists {
            guard payload.schemaVersion == 1 else {
                rejections.append(SyncRejection(
                    planID: payload.planID,
                    code: .syncInvalidState,
                    message: "Unsupported shopping list schema version."
                ))
                continue
            }
            let maybeRole = try await access.role(for: payload.planID, userID: userID)
            guard let role = maybeRole, role.canEdit else {
                rejections.append(SyncRejection(
                    planID: payload.planID,
                    code: maybeRole == nil ? .planAccessRevoked : .planRoleInsufficient,
                    message: "You cannot modify this shopping list."
                ))
                continue
            }
            guard let stored = try await ShoppingListDocumentModel.find(payload.planID, on: db) else {
                rejections.append(SyncRejection(
                    planID: payload.planID,
                    code: .notFound,
                    message: "Shopping list not found."
                ))
                continue
            }
            let merged = stored.state.merged(with: payload.state)
            stored.state = merged
            stored.stateHash = merged.stateHash
            stored.schemaVersion = merged.schemaVersion
            stored.sourcePlanHash = merged.sourcePlanHash.value
            stored.updatedAt = Date()
            try await stored.save(on: db)
            responseShopping.append(SyncShoppingPayload(planID: payload.planID, state: merged))
        }

        let now = Date()
        return SyncPushResponse(
            plans: responsePlans,
            shoppingLists: responseShopping,
            rejections: rejections,
            warnings: warnings,
            cursor: SyncCursor(value: ISO8601DateFormatter().string(from: now), serverTime: now)
        )
    }

    private func protectedFieldRejection(
        incoming: PlanDocument,
        stored: PlanDocument,
        planID: UUID
    ) -> SyncRejection? {
        func advanced<Value: Equatable>(
            _ field: LWWRegister<Value>,
            _ storedField: LWWRegister<Value>
        ) -> Bool {
            field.value != storedField.value && field.clock > storedField.clock
        }

        let changed =
            advanced(incoming.metadata.name, stored.metadata.name)
            || advanced(incoming.metadata.startDate, stored.metadata.startDate)
            || advanced(incoming.metadata.dayCount, stored.metadata.dayCount)
            || advanced(incoming.metadata.slots, stored.metadata.slots)
            || advanced(incoming.metadata.rules, stored.metadata.rules)
            || advanced(incoming.metadata.deleted, stored.metadata.deleted)

        guard changed else { return nil }
        return SyncRejection(
            planID: planID,
            code: .planRoleInsufficient,
            message: "Only the owner can change plan settings."
        )
    }
}
