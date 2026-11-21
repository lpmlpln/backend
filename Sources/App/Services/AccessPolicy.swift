import Fluent
import Foundation
import MealPlannerCore
import Vapor

struct AccessPolicy: Sendable {
    let db: any Database

    // MARK: Friends

    func areFriends(_ userA: UUID, _ userB: UUID) async throws -> Bool {
        if userA == userB { return true }
        let sorted = [userA, userB].sorted { $0.uuidString < $1.uuidString }
        return try await FriendshipModel.query(on: db)
            .filter(\.$userA.$id == sorted[0])
            .filter(\.$userB.$id == sorted[1])
            .first() != nil
    }

    // MARK: Recipes

    func canView(recipe: RecipeModel, userID: UUID) async throws -> Bool {
        if let ownerID = recipe.$owner.id, ownerID == userID { return true }
        if recipe.visibility == "public" { return true }
        guard let recipeID = recipe.id else { return false }
        return try await RecipeShareModel.query(on: db)
            .filter(\.$recipe.$id == recipeID)
            .filter(\.$sharedWith.$id == userID)
            .filter(\.$revokedAt == nil)
            .first() != nil
    }

    func canEdit(recipe: RecipeModel, userID: UUID) async throws -> Bool {
        guard let ownerID = recipe.$owner.id else { return false }
        return ownerID == userID && !recipe.isImported
    }

    func assertCanView(recipe: RecipeModel, userID: UUID) async throws {
        guard try await canView(recipe: recipe, userID: userID) else {
            throw AppError.notFound()
        }
    }

    func assertCanEdit(recipe: RecipeModel, userID: UUID) async throws {
        guard try await canEdit(recipe: recipe, userID: userID) else {
            if recipe.isImported {
                throw AppError.validation("Imported recipes are immutable. Personalize your own version instead.")
            }
            throw AppError.forbidden()
        }
    }

    // MARK: Plans

    func role(for planID: UUID, userID: UUID) async throws -> PlanRole? {
        guard let member = try await PlanMemberModel.query(on: db)
            .filter(\.$plan.$id == planID)
            .filter(\.$user.$id == userID)
            .filter(\.$revokedAt == nil)
            .first()
        else { return nil }
        return member.planRole
    }

    func assertRole(
        for planID: UUID,
        userID: UUID,
        minimum: PlanRole = .viewer
    ) async throws -> PlanRole {
        guard let role = try await role(for: planID, userID: userID) else {
            throw AppError.accessRevoked()
        }
        switch minimum {
        case .viewer:
            return role
        case .editor:
            guard role == .owner || role == .editor else {
                throw AppError.roleInsufficient()
            }
            return role
        case .owner:
            guard role == .owner else {
                throw AppError.roleInsufficient()
            }
            return role
        }
    }
}
