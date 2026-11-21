import Fluent
import Foundation
import MealPlannerCore
import Vapor

struct RecipeController: Sendable {
    func register(routes: some RoutesBuilder) {
        routes.get("recipes", use: list)
        routes.post("recipes", use: create)
        routes.get("recipes", ":recipeID", use: detail)
        routes.patch("recipes", ":recipeID", use: update)
        routes.delete("recipes", ":recipeID", use: delete)
        routes.post("recipes", ":recipeID", "favorite", use: favorite)
        routes.delete("recipes", ":recipeID", "favorite", use: unfavorite)
        routes.post("recipes", ":recipeID", "block", use: block)
        routes.delete("recipes", ":recipeID", "block", use: unblock)
        routes.put("recipes", ":recipeID", "personalization", use: setPersonalization)
        routes.post("recipes", ":recipeID", "share", use: share)
        routes.post("recipes", "import", use: startImport)
        routes.get("recipes", "import", ":jobID", use: importStatus)
        routes.post("recipes", "import", ":jobID", "run", use: runImport)
    }

    private func planning(_ request: Request) -> PlanningService {
        PlanningService(db: request.db, access: AccessPolicy(db: request.db))
    }

    @Sendable
    func list(_ request: Request) async throws -> RecipeListResponse {
        let userID = try request.requireUserID()
        var recipes = try await planning(request).accessibleRecipes(userID: userID)

        if let query = request.query[String.self, at: "q"]?.lowercased(), !query.isEmpty {
            recipes = recipes.filter {
                $0.title.lowercased().contains(query)
                    || $0.ingredients.contains { $0.name.lowercased().contains(query) }
            }
        }
        if let cuisine = request.query[String.self, at: "cuisine"] {
            recipes = recipes.filter { $0.cuisine?.lowercased() == cuisine.lowercased() }
        }
        if let dishType = request.query[String.self, at: "dishType"] {
            recipes = recipes.filter { $0.dishType?.lowercased() == dishType.lowercased() }
        }
        if let maxMinutes = request.query[Int.self, at: "maxMinutes"] {
            recipes = recipes.filter { ($0.effective().totalMinutes ?? Int.max) <= maxMinutes }
        }
        if request.query[String.self, at: "favorites"] == "true" {
            recipes = recipes.filter(\.isFavorite)
        }
        if request.query[String.self, at: "excludeBlocked"] != "false" {
            recipes = recipes.filter { !$0.isBlocked }
        }

        // Cursor is an offset for the simple list endpoint.
        let offset = request.query[Int.self, at: "offset"] ?? 0
        let limit = min(request.query[Int.self, at: "limit"] ?? 50, 100)
        let page = Array(recipes.dropFirst(offset).prefix(limit))
        let next = offset + page.count < recipes.count ? String(offset + page.count) : nil
        return RecipeListResponse(items: page, nextCursor: next)
    }

    @Sendable
    func detail(_ request: Request) async throws -> RecipeDTO {
        let userID = try request.requireUserID()
        guard let id = request.parameters.get("recipeID", as: UUID.self),
              let recipe = try await RecipeModel.find(id, on: request.db),
              recipe.deletedAt == nil
        else { throw AppError.notFound() }
        try await AccessPolicy(db: request.db).assertCanView(recipe: recipe, userID: userID)
        return try await planning(request).dto(for: recipe, userID: userID)
    }

    @Sendable
    func create(_ request: Request) async throws -> RecipeDTO {
        let userID = try request.requireUserID()
        let body = try request.content.decode(RecipeCreateRequest.self)
        guard !body.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.validation("A title is required.")
        }
        guard body.servings > 0 else {
            throw AppError.validation("Servings must be positive.")
        }
        guard !body.ingredients.isEmpty, !body.instructions.isEmpty else {
            throw AppError.validation("At least one ingredient and one instruction are required.")
        }

        let recipe = RecipeModel(
            ownerID: userID,
            title: body.title,
            description: body.description,
            servings: body.servings,
            prepMinutes: body.prepMinutes,
            cookMinutes: body.cookMinutes,
            instructions: body.instructions,
            cuisine: body.cuisine,
            dishType: body.dishType,
            mainIngredient: body.mainIngredient,
            dietaryTags: body.dietaryTags.map { $0.lowercased() },
            visibility: body.visibility.rawValue
        )
        try await recipe.save(on: request.db)
        let recipeID = try recipe.requireID()

        for (index, ingredient) in body.ingredients.enumerated() {
            try await RecipeIngredientModel(
                recipeID: recipeID,
                name: ingredient.name,
                normalizedName: IngredientNormalizer.normalize(ingredient.name),
                quantity: ingredient.quantity,
                unit: ingredient.unit,
                note: ingredient.note,
                category: ingredient.category.rawValue,
                sortOrder: index
            ).save(on: request.db)
        }

        return try await planning(request).dto(for: recipe, userID: userID)
    }

    @Sendable
    func update(_ request: Request) async throws -> RecipeDTO {
        let userID = try request.requireUserID()
        guard let id = request.parameters.get("recipeID", as: UUID.self),
              let recipe = try await RecipeModel.find(id, on: request.db)
        else { throw AppError.notFound() }
        try await AccessPolicy(db: request.db).assertCanEdit(recipe: recipe, userID: userID)

        let body = try request.content.decode(RecipeCreateRequest.self)
        recipe.title = body.title
        recipe.description = body.description
        recipe.servings = body.servings
        recipe.prepMinutes = body.prepMinutes
        recipe.cookMinutes = body.cookMinutes
        recipe.instructions = body.instructions
        recipe.cuisine = body.cuisine
        recipe.dishType = body.dishType
        recipe.mainIngredient = body.mainIngredient
        recipe.dietaryTags = body.dietaryTags.map { $0.lowercased() }
        recipe.visibility = body.visibility.rawValue
        recipe.updatedAt = Date()
        try await recipe.save(on: request.db)

        let existing = try await RecipeIngredientModel.query(on: request.db)
            .filter(\.$recipe.$id == id).all()
        for ingredient in existing { try await ingredient.delete(on: request.db) }
        for (index, ingredient) in body.ingredients.enumerated() {
            try await RecipeIngredientModel(
                recipeID: id,
                name: ingredient.name,
                normalizedName: IngredientNormalizer.normalize(ingredient.name),
                quantity: ingredient.quantity,
                unit: ingredient.unit,
                note: ingredient.note,
                category: ingredient.category.rawValue,
                sortOrder: index
            ).save(on: request.db)
        }

        return try await planning(request).dto(for: recipe, userID: userID)
    }

    @Sendable
    func delete(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        guard let id = request.parameters.get("recipeID", as: UUID.self),
              let recipe = try await RecipeModel.find(id, on: request.db)
        else { throw AppError.notFound() }
        try await AccessPolicy(db: request.db).assertCanEdit(recipe: recipe, userID: userID)
        try await recipe.delete(on: request.db)
        return .noContent
    }

    @Sendable
    func favorite(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        let id = try requireRecipeID(request)
        try await AccessPolicy(db: request.db).assertCanView(
            recipe: try await findRecipe(id, request), userID: userID
        )
        if try await RecipeFavoriteModel.query(on: request.db)
            .filter(\.$user.$id == userID).filter(\.$recipe.$id == id).first() == nil {
            try await RecipeFavoriteModel(userID: userID, recipeID: id).save(on: request.db)
        }
        return .ok
    }

    @Sendable
    func unfavorite(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        let id = try requireRecipeID(request)
        for model in try await RecipeFavoriteModel.query(on: request.db)
            .filter(\.$user.$id == userID).filter(\.$recipe.$id == id).all() {
            try await model.delete(on: request.db)
        }
        return .noContent
    }

    @Sendable
    func block(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        let id = try requireRecipeID(request)
        if try await RecipeBlockModel.query(on: request.db)
            .filter(\.$user.$id == userID).filter(\.$recipe.$id == id).first() == nil {
            try await RecipeBlockModel(userID: userID, recipeID: id).save(on: request.db)
        }
        return .ok
    }

    @Sendable
    func unblock(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        let id = try requireRecipeID(request)
        for model in try await RecipeBlockModel.query(on: request.db)
            .filter(\.$user.$id == userID).filter(\.$recipe.$id == id).all() {
            try await model.delete(on: request.db)
        }
        return .noContent
    }

    @Sendable
    func setPersonalization(_ request: Request) async throws -> RecipeDTO {
        let userID = try request.requireUserID()
        let id = try requireRecipeID(request)
        let recipe = try await findRecipe(id, request)
        try await AccessPolicy(db: request.db).assertCanView(recipe: recipe, userID: userID)

        let body = try request.content.decode(PersonalizationDTO.self)
        let model = try await RecipePersonalizationModel.query(on: request.db)
            .filter(\.$user.$id == userID).filter(\.$recipe.$id == id).first()
            ?? RecipePersonalizationModel(userID: userID, recipeID: id)
        model.title = body.title
        model.servings = body.servings
        model.instructions = body.instructions
        model.ingredients = body.ingredients
        model.notes = body.notes
        model.updatedAt = Date()
        if model.id != nil {
            try await model.save(on: request.db)
        } else {
            try await model.create(on: request.db)
        }

        return try await planning(request).dto(for: recipe, userID: userID)
    }

    @Sendable
    func share(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        let id = try requireRecipeID(request)
        let recipe = try await findRecipe(id, request)
        try await AccessPolicy(db: request.db).assertCanEdit(recipe: recipe, userID: userID)
        let body = try request.content.decode(FriendRequestLike.self)
        guard try await AccessPolicy(db: request.db).areFriends(userID, body.userID) else {
            throw AppError.validation("Only friends can receive recipe shares.")
        }
        if let existing = try await RecipeShareModel.query(on: request.db)
            .filter(\.$recipe.$id == id).filter(\.$sharedWith.$id == body.userID).first() {
            existing.revokedAt = nil
            try await existing.save(on: request.db)
        } else {
            try await RecipeShareModel(recipeID: id, sharedWithUserID: body.userID).save(on: request.db)
        }
        return .ok
    }

    @Sendable
    func startImport(_ request: Request) async throws -> RecipeImportResponse {
        let userID = try request.requireUserID()
        let body = try request.content.decode(RecipeImportRequest.self)
        return try await request.application.importService.start(userID: userID, rawURL: body.url)
    }

    @Sendable
    func importStatus(_ request: Request) async throws -> ImportJobDTO {
        let userID = try request.requireUserID()
        guard let jobID = request.parameters.get("jobID", as: UUID.self) else {
            throw AppError.notFound()
        }
        return try await request.application.importService.job(jobID, userID: userID)
    }

    @Sendable
    func runImport(_ request: Request) async throws -> RecipeImportResponse {
        _ = try request.requireUserID()
        guard let jobID = request.parameters.get("jobID", as: UUID.self) else {
            throw AppError.notFound()
        }
        return try await request.application.importService.process(jobID: jobID)
    }

    private func requireRecipeID(_ request: Request) throws -> UUID {
        guard let id = request.parameters.get("recipeID", as: UUID.self) else {
            throw AppError.notFound()
        }
        return id
    }

    private func findRecipe(_ id: UUID, _ request: Request) async throws -> RecipeModel {
        guard let recipe = try await RecipeModel.find(id, on: request.db), recipe.deletedAt == nil else {
            throw AppError.notFound()
        }
        return recipe
    }
}

struct FriendRequestLike: Codable, Sendable {
    var userID: UUID
}
