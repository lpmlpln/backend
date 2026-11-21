import Fluent
import Foundation
import MealPlannerCore
import Vapor

struct PlanningService: Sendable {
    let db: any Database
    let access: AccessPolicy

    // MARK: - Candidates

    func accessibleRecipes(userID: UUID) async throws -> [RecipeDTO] {
        let recipes = try await RecipeModel.query(on: db)
            .filter(\.$deletedAt == nil)
            .all()
        var result: [RecipeDTO] = []
        for recipe in recipes {
            guard try await access.canView(recipe: recipe, userID: userID) else { continue }
            result.append(try await dto(for: recipe, userID: userID))
        }
        return result
    }

    func dto(for recipe: RecipeModel, userID: UUID) async throws -> RecipeDTO {
        let ingredients = try await RecipeIngredientModel.query(on: db)
            .filter(\.$recipe.$id == recipe.requireID())
            .sort(\.$sortOrder)
            .all()
            .map { $0.dto() }

        let personalization = try await RecipePersonalizationModel.query(on: db)
            .filter(\.$recipe.$id == recipe.requireID())
            .filter(\.$user.$id == userID)
            .first()?
            .dto()

        let isFavorite = try await RecipeFavoriteModel.query(on: db)
            .filter(\.$recipe.$id == recipe.requireID())
            .filter(\.$user.$id == userID)
            .first() != nil

        let isBlocked = try await RecipeBlockModel.query(on: db)
            .filter(\.$recipe.$id == recipe.requireID())
            .filter(\.$user.$id == userID)
            .first() != nil

        let imageURLs: [URL] = []
        // Image URLs are presigned by the API when returned; the core DTO stores URLs.
        // The storage service fills these in the controller layer.

        return RecipeDTO(
            id: try recipe.requireID(),
            ownerID: recipe.$owner.id,
            title: recipe.title,
            description: recipe.description,
            servings: recipe.servings,
            prepMinutes: recipe.prepMinutes,
            cookMinutes: recipe.cookMinutes,
            ingredients: ingredients,
            instructions: recipe.instructions,
            cuisine: recipe.cuisine,
            dishType: recipe.dishType,
            mainIngredient: recipe.mainIngredient,
            dietaryTags: recipe.dietaryTags,
            images: imageURLs.map { RecipeImageDTO(url: $0) },
            visibility: recipe.visibility == "public" ? .public : .private,
            isImported: recipe.isImported,
            sourceURL: recipe.sourceURL.flatMap(URL.init(string:)),
            isFavorite: isFavorite,
            isBlocked: isBlocked,
            isOwner: recipe.$owner.id == userID,
            personalization: personalization,
            updatedAt: recipe.updatedAt ?? Date()
        )
    }

    func planningCandidates(userID: UUID) async throws -> [PlanningCandidate] {
        let recipes = try await accessibleRecipes(userID: userID)
        return recipes.compactMap { dto in
            guard !dto.isBlocked else { return nil }
            return PlanningCandidate(
                recipe: dto.effective(),
                isFavorite: dto.isFavorite
            )
        }
    }

    // MARK: - Plan creation

    func createPlan(userID: UUID, request: PlanCreateRequest) async throws -> PlanDTO {
        guard request.dayCount >= 1, request.dayCount <= 60 else {
            throw AppError.validation("dayCount must be between 1 and 60.")
        }
        guard !request.slots.isEmpty else {
            throw AppError.validation("At least one meal slot is required.")
        }

        let planID = UUID()
        let planModel = MealPlanModel(
            id: planID,
            ownerID: userID,
            name: request.name,
            startDate: request.startDate,
            dayCount: request.dayCount,
            slots: request.slots,
            rules: request.rules
        )
        try await planModel.save(on: db)
        try await PlanMemberModel(planID: planID, userID: userID, role: .owner).save(on: db)

        let clock = serverClock()
        let result = try await generateEntries(
            planID: planID,
            startDate: request.startDate,
            dayCount: request.dayCount,
            slots: request.slots,
            rules: request.rules,
            userID: userID,
            locked: [:],
            seed: request.seed ?? 0,
            clock: clock
        )

        let plan = Plan(
            id: planID,
            ownerID: userID,
            name: request.name,
            startDate: request.startDate,
            dayCount: request.dayCount,
            slots: request.slots,
            rules: request.rules,
            entries: result.entries
        )
        let document = PlanDocument(plan: plan, clock: clock)
        try await PlanDocumentModel(planID: planID, state: document).save(on: db)
        try await regenerateShoppingList(planID: planID, userID: userID, clock: clock)

        return try await planDTO(planID: planID, userID: userID, warnings: result.warnings.map(\.message))
    }

    private func generateEntries(
        planID: UUID,
        startDate: CalendarDate,
        dayCount: Int,
        slots: [MealSlot],
        rules: PlanRules,
        userID: UUID,
        locked: [PlanEntryKey: PlanEntry],
        seed: UInt64,
        clock: HLC
    ) async throws -> PlanGenerationResult {
        let generator = MealPlanGenerator()
        let result = generator.generate(
            PlanGenerationRequest(
                planID: planID,
                startDate: startDate,
                dayCount: dayCount,
                slots: slots,
                rules: rules,
                candidates: try await planningCandidates(userID: userID),
                lockedEntries: locked,
                seed: seed
            )
        )
        guard result.isSuccess else {
            throw AppError.validation(result.failure?.message ?? "Could not generate a plan.")
        }
        return result
    }

    // MARK: - Reading

    func accessiblePlans(userID: UUID) async throws -> [MealPlanModel] {
        let memberPlanIDs = try await PlanMemberModel.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$revokedAt == nil)
            .all()
            .map { $0.$plan.id }
        guard !memberPlanIDs.isEmpty else { return [] }
        return try await MealPlanModel.query(on: db)
            .filter(\.$id ~~ memberPlanIDs)
            .filter(\.$deletedAt == nil)
            .sort(\.$updatedAt, .descending)
            .all()
    }

    func planModel(_ planID: UUID) async throws -> MealPlanModel {
        guard let plan = try await MealPlanModel.find(planID, on: db), plan.deletedAt == nil else {
            throw AppError.notFound("Plan not found.")
        }
        return plan
    }

    func planDocument(_ planID: UUID) async throws -> PlanDocument {
        guard let record = try await PlanDocumentModel.find(planID, on: db) else {
            throw AppError.notFound("Plan document not found.")
        }
        return record.state
    }

    func planDTO(planID: UUID, userID: UUID, warnings: [String] = []) async throws -> PlanDTO {
        let plan = try await planModel(planID)
        let role = try await access.assertRole(for: planID, userID: userID)
        let document = try await planDocument(planID)
        let members = try await PlanMemberModel.query(on: db)
            .filter(\.$plan.$id == planID)
            .filter(\.$revokedAt == nil)
            .all()

        var memberDTOs: [PlanMemberDTO] = []
        for member in members {
            guard let user = try await UserModel.find(member.$user.id, on: db) else { continue }
            memberDTOs.append(
                PlanMemberDTO(
                    userID: try user.requireID(),
                    displayName: user.displayName,
                    email: user.email,
                    role: member.planRole,
                    joinedAt: member.createdAt ?? Date()
                )
            )
        }

        let recipes = try await accessibleRecipes(userID: userID)
        let recipesByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0) })
        let blockedIDs = Set(recipes.filter(\.isBlocked).map(\.id))
        var entryDTOs: [PlanEntryDTO] = []
        var warnings = warnings

        for entry in document.materializedEntries() {
            if blockedIDs.contains(entry.recipeID) {
                warnings.append("A blocked recipe is used on \(entry.key.date.isoString).")
            }
            let recipe = recipesByID[entry.recipeID]
            entryDTOs.append(
                PlanEntryDTO(
                    date: entry.key.date,
                    slot: entry.key.slot,
                    recipeID: entry.recipeID,
                    recipeTitle: recipe?.effective().title ?? entry.recipeTitleSnapshot ?? "Unavailable recipe",
                    imageURL: recipe?.images.first?.url,
                    servings: entry.servings,
                    isLocked: entry.isLocked,
                    isLeftover: entry.isLeftover,
                    batchID: entry.batchID
                )
            )
        }

        let shopping = try await shoppingDTO(planID: planID, userID: userID)
        return PlanDTO(
            id: planID,
            ownerID: plan.$owner.id,
            name: document.metadata.name.value,
            startDate: document.metadata.startDate.value,
            dayCount: document.metadata.dayCount.value,
            slots: document.metadata.slots.value,
            rules: document.metadata.rules.value,
            myRole: role,
            members: memberDTOs,
            entries: entryDTOs,
            shoppingList: shopping,
            warnings: warnings,
            updatedAt: plan.updatedAt ?? Date()
        )
    }

    // MARK: - Mutations

    func updatePlan(planID: UUID, userID: UUID, request: PlanUpdateRequest) async throws -> PlanDTO {
        _ = try await access.assertRole(for: planID, userID: userID, minimum: .owner)
        let plan = try await planModel(planID)
        var document = try await planDocument(planID)

        if let name = request.name { document.metadata.name = document.metadata.name.updated(to: name, at: serverClock()) }
        if let startDate = request.startDate { document.metadata.startDate = document.metadata.startDate.updated(to: startDate, at: serverClock()) }
        if let dayCount = request.dayCount {
            guard (1...60).contains(dayCount) else { throw AppError.validation("dayCount must be between 1 and 60.") }
            document.metadata.dayCount = document.metadata.dayCount.updated(to: dayCount, at: serverClock())
        }
        if let slots = request.slots {
            guard !slots.isEmpty else { throw AppError.validation("At least one meal slot is required.") }
            document.metadata.slots = document.metadata.slots.updated(to: slots, at: serverClock())
            plan.slots = slots.map(\.rawValue)
        }
        if let rules = request.rules {
            document.metadata.rules = document.metadata.rules.updated(to: rules, at: serverClock())
            plan.rules = rules
        }

        if let name = request.name { plan.name = name }
        if let startDate = request.startDate { plan.startDate = startDate.isoString }
        if let dayCount = request.dayCount { plan.dayCount = dayCount }

        try await save(document: document, planID: planID)
        try await plan.save(on: db)
        return try await planDTO(planID: planID, userID: userID)
    }

    func recalculate(planID: UUID, userID: UUID, seed: UInt64?) async throws -> PlanDTO {
        _ = try await access.assertRole(for: planID, userID: userID, minimum: .editor)
        let plan = try await planModel(planID)
        let document = try await planDocument(planID)
        let locked = Dictionary(
            uniqueKeysWithValues: document.materializedEntries()
                .filter(\.isLocked)
                .map { ($0.key, $0) }
        )

        let result = try await generateEntries(
            planID: planID,
            startDate: plan.calendarStartDate,
            dayCount: plan.dayCount,
            slots: plan.mealSlots,
            rules: plan.rules,
            userID: userID,
            locked: locked,
            seed: seed ?? UInt64(Date().timeIntervalSince1970),
            clock: serverClock()
        )

        var updated = document
        updated.apply(plan: updated.materialize(ownerID: plan.$owner.id, entries: result.entries), clock: serverClock(), replaceEntries: true)
        try await save(document: updated, planID: planID)
        try await regenerateShoppingList(planID: planID, userID: userID)

        return try await planDTO(planID: planID, userID: userID, warnings: result.warnings.map(\.message))
    }

    func changeEntry(planID: UUID, userID: UUID, key: PlanEntryKey, request: PlanEntryUpdateRequest) async throws -> PlanDTO {
        _ = try await access.assertRole(for: planID, userID: userID, minimum: .editor)
        let recipes = try await accessibleRecipes(userID: userID)
        guard let recipeDTO = recipes.first(where: { $0.id == request.recipeID }) else {
            throw AppError(.recipeUnavailable, status: .badRequest, message: "That recipe is not available.")
        }

        var document = try await planDocument(planID)
        var entry = document.materializedEntries().first { $0.key == key }
            ?? PlanEntry(key: key, recipeID: request.recipeID, servings: recipeDTO.servings)
        entry.recipeID = request.recipeID
        entry.servings = request.servings ?? recipeDTO.servings
        entry.recipeTitleSnapshot = recipeDTO.effective().title
        if let lock = request.lock { entry.isLocked = lock }
        let clock = serverClock()
        document.apply(entry: entry, clock: clock)

        if request.applyToBatch == true, let batchID = entry.batchID {
            for other in document.materializedEntries() where other.batchID == batchID && other.key != key {
                var copy = other
                copy.recipeID = request.recipeID
                copy.recipeTitleSnapshot = entry.recipeTitleSnapshot
                document.apply(entry: copy, clock: clock)
            }
        }

        try await save(document: document, planID: planID)
        try await regenerateShoppingList(planID: planID, userID: userID, clock: clock)
        return try await planDTO(planID: planID, userID: userID)
    }

    func setLock(planID: UUID, userID: UUID, key: PlanEntryKey, locked: Bool) async throws -> PlanDTO {
        _ = try await access.assertRole(for: planID, userID: userID, minimum: .editor)
        var document = try await planDocument(planID)
        document.setLocked(locked, entryKey: key, clock: serverClock())
        try await save(document: document, planID: planID)
        return try await planDTO(planID: planID, userID: userID)
    }

    func deletePlan(planID: UUID, userID: UUID) async throws {
        _ = try await access.assertRole(for: planID, userID: userID, minimum: .owner)
        guard let plan = try await MealPlanModel.find(planID, on: db) else { throw AppError.notFound() }
        try await plan.delete(on: db)
        try await AuditLogModel(
            actorUserID: userID,
            action: "plan.delete",
            entityType: "plan",
            entityID: planID
        ).save(on: db)
    }

    // MARK: - Members

    func addMember(planID: UUID, userID: UUID, memberID: UUID, role: PlanRole) async throws -> PlanDTO {
        _ = try await access.assertRole(for: planID, userID: userID, minimum: .owner)
        guard try await access.areFriends(userID, memberID) || userID == memberID else {
            throw AppError.validation("Only accepted friends can be added to a plan.")
        }

        if let existing = try await PlanMemberModel.query(on: db)
            .filter(\.$plan.$id == planID)
            .filter(\.$user.$id == memberID)
            .first() {
            if existing.revokedAt != nil {
                existing.revokedAt = nil
                existing.role = role.rawValue
                try await existing.save(on: db)
            } else {
                existing.role = role.rawValue
                try await existing.save(on: db)
            }
        } else {
            try await PlanMemberModel(
                planID: planID,
                userID: memberID,
                role: role,
                invitedBy: userID
            ).save(on: db)
        }

        try await AuditLogModel(
            actorUserID: userID,
            action: "plan.member.add",
            entityType: "plan",
            entityID: planID,
            metadata: ["userID": memberID.uuidString, "role": role.rawValue]
        ).save(on: db)

        return try await planDTO(planID: planID, userID: userID)
    }

    func removeMember(planID: UUID, userID: UUID, memberID: UUID) async throws -> PlanDTO {
        _ = try await access.assertRole(for: planID, userID: userID, minimum: .owner)
        guard memberID != userID else {
            throw AppError.validation("The owner cannot be removed.")
        }
        guard let member = try await PlanMemberModel.query(on: db)
            .filter(\.$plan.$id == planID)
            .filter(\.$user.$id == memberID)
            .filter(\.$revokedAt == nil)
            .first()
        else { throw AppError.notFound() }
        member.revokedAt = Date()
        try await member.save(on: db)

        try await AuditLogModel(
            actorUserID: userID,
            action: "plan.member.remove",
            entityType: "plan",
            entityID: planID,
            metadata: ["userID": memberID.uuidString]
        ).save(on: db)

        return try await planDTO(planID: planID, userID: userID)
    }

    // MARK: - Shopping list

    func regenerateShoppingList(planID: UUID, userID: UUID, clock: HLC? = nil) async throws {
        let document = try await planDocument(planID)
        let plan = document.materialize(ownerID: UUID())
        let recipes = try await accessibleRecipes(userID: userID)
        let recipesByID = Dictionary(uniqueKeysWithValues: recipes.map { ($0.id, $0.effective()) })

        var inputs: [ShoppingIngredientInput] = []
        for entry in plan.entries {
            guard let recipe = recipesByID[entry.recipeID] else { continue }
            inputs.append(
                ShoppingIngredientInput(
                    recipe: recipe,
                    servings: entry.servings,
                    isLeftover: entry.isLeftover
                )
            )
        }

        let list = IngredientAggregator().aggregate(
            planID: planID,
            entries: inputs,
            sourcePlanHash: document.stateHash
        )
        let effectiveClock = clock ?? serverClock()
        let shoppingDocument = ShoppingListDocument(list: list, clock: effectiveClock)
        let itemKeys = Set(list.items.map(\.key))

        if let existing = try await ShoppingListDocumentModel.find(planID, on: db) {
            // Preserve checked state for items that still exist.
            var merged = existing.state.merged(with: shoppingDocument)
            for (key, state) in existing.state.items where itemKeys.contains(key) {
                var updated = merged.items[key] ?? state
                updated.checked = state.checked
                merged.items[key] = updated
            }
            existing.state = merged
            existing.stateHash = merged.stateHash
            existing.schemaVersion = merged.schemaVersion
            existing.sourcePlanHash = merged.sourcePlanHash.value
            existing.generatedAt = Date()
            existing.updatedAt = Date()
            try await existing.save(on: db)
        } else {
            try await ShoppingListDocumentModel(
                planID: planID,
                state: shoppingDocument,
                generatedAt: Date()
            ).save(on: db)
        }
    }

    func shoppingDTO(planID: UUID, userID: UUID) async throws -> ShoppingListDTO? {
        _ = try await access.assertRole(for: planID, userID: userID)
        guard let record = try await ShoppingListDocumentModel.find(planID, on: db) else { return nil }
        let planDocument = try await planDocument(planID)
        let isStale = record.sourcePlanHash != planDocument.stateHash
        return ShoppingListDTO(
            planID: planID,
            items: record.state.materializedItems().map(ShoppingItemDTO.init(item:)),
            isStale: isStale,
            generatedAt: record.generatedAt
        )
    }

    func setChecked(planID: UUID, userID: UUID, itemKey: String, isChecked: Bool, clock: HLC? = nil) async throws -> ShoppingListDTO {
        _ = try await access.assertRole(for: planID, userID: userID, minimum: .editor)
        guard let record = try await ShoppingListDocumentModel.find(planID, on: db) else {
            throw AppError.notFound("Shopping list not found.")
        }
        var document = record.state
        document.setChecked(isChecked, itemKey: itemKey, clock: clock ?? serverClock())
        record.state = document
        record.stateHash = document.stateHash
        record.updatedAt = Date()
        try await record.save(on: db)
        return try await shoppingDTO(planID: planID, userID: userID) ?? ShoppingListDTO(planID: planID, items: [], generatedAt: Date())
    }

    // MARK: - Helpers

    func save(document: PlanDocument, planID: UUID) async throws {
        if let existing = try await PlanDocumentModel.find(planID, on: db) {
            existing.schemaVersion = document.schemaVersion
            existing.state = document
            existing.stateHash = document.stateHash
            existing.updatedAt = Date()
            try await existing.save(on: db)
        } else {
            try await PlanDocumentModel(planID: planID, state: document).save(on: db)
        }
        if let plan = try await MealPlanModel.find(planID, on: db) {
            plan.updatedAt = Date()
            try await plan.save(on: db)
        }
    }

    private func serverClock() -> HLC {
        HLC(
            wallTimeMillis: Int64(Date().timeIntervalSince1970 * 1_000),
            counter: UInt32.random(in: 0..<1_000),
            nodeID: ServerClock.nodeID
        )
    }
}

enum ServerClock {
    static let nodeID = UUID()
}
