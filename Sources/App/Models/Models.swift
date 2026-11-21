import Fluent
import Foundation
import MealPlannerCore
import Vapor

// MARK: - Identity

final class UserModel: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String
    @Field(key: "display_name") var displayName: String
    @OptionalField(key: "apple_subject_id") var appleSubjectID: String?
    @Field(key: "is_admin") var isAdmin: Bool
    @Field(key: "is_disabled") var isDisabled: Bool
    @Field(key: "measurement_system") var measurementSystem: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        email: String,
        displayName: String,
        appleSubjectID: String? = nil,
        isAdmin: Bool = false,
        isDisabled: Bool = false,
        measurementSystem: String = "metric"
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.appleSubjectID = appleSubjectID
        self.isAdmin = isAdmin
        self.isDisabled = isDisabled
        self.measurementSystem = measurementSystem
    }

    func dto() throws -> UserDTO {
        UserDTO(
            id: try requireID(),
            email: email,
            displayName: displayName,
            isAdmin: isAdmin,
            measurementSystem: MeasurementSystem(rawValue: measurementSystem) ?? .metric,
            createdAt: createdAt ?? Date()
        )
    }
}

final class UserDeviceModel: Model, @unchecked Sendable {
    static let schema = "user_devices"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "name") var name: String
    @Field(key: "platform") var platform: String
    @Field(key: "last_seen_at") var lastSeenAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID, userID: UUID, name: String, platform: String) {
        self.id = id
        self.$user.id = userID
        self.name = name
        self.platform = platform
        self.lastSeenAt = Date()
    }
}

final class MagicLinkTokenModel: Model, @unchecked Sendable {
    static let schema = "magic_link_tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String
    @OptionalParent(key: "user_id") var user: UserModel?
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "client") var client: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "consumed_at") var consumedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "request_ip") var requestIP: String?
    @OptionalField(key: "user_agent") var userAgent: String?

    init() {}

    init(email: String, userID: UUID?, tokenHash: String, client: String, expiresAt: Date, requestIP: String?, userAgent: String?) {
        self.email = email
        self.$user.id = userID
        self.tokenHash = tokenHash
        self.client = client
        self.expiresAt = expiresAt
        self.requestIP = requestIP
        self.userAgent = userAgent
    }
}

final class RefreshTokenModel: Model, @unchecked Sendable {
    static let schema = "refresh_tokens"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "device_id") var device: UserDeviceModel
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, deviceID: UUID, tokenHash: String, expiresAt: Date) {
        self.$user.id = userID
        self.$device.id = deviceID
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }
}

final class AdminSessionModel: Model, @unchecked Sendable {
    static let schema = "admin_sessions"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "session_token_hash") var sessionTokenHash: String
    @Field(key: "expires_at") var expiresAt: Date
    @Field(key: "last_seen_at") var lastSeenAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, sessionTokenHash: String, expiresAt: Date) {
        self.$user.id = userID
        self.sessionTokenHash = sessionTokenHash
        self.expiresAt = expiresAt
        self.lastSeenAt = Date()
    }
}

// MARK: - Friends

final class FriendRequestModel: Model, @unchecked Sendable {
    static let schema = "friend_requests"

    @ID(key: .id) var id: UUID?
    @Parent(key: "from_user_id") var fromUser: UserModel
    @Parent(key: "to_user_id") var toUser: UserModel
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "responded_at") var respondedAt: Date?

    init() {}

    init(fromUserID: UUID, toUserID: UUID, status: String = "pending") {
        self.$fromUser.id = fromUserID
        self.$toUser.id = toUserID
        self.status = status
    }
}

final class FriendshipModel: Model, @unchecked Sendable {
    static let schema = "friendships"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_a_id") var userA: UserModel
    @Parent(key: "user_b_id") var userB: UserModel
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userAID: UUID, userBID: UUID) {
        let sorted = [userAID, userBID].sorted { $0.uuidString < $1.uuidString }
        self.$userA.id = sorted[0]
        self.$userB.id = sorted[1]
    }
}

// MARK: - Recipes

final class RecipeModel: Model, @unchecked Sendable {
    static let schema = "recipes"

    @ID(key: .id) var id: UUID?
    @OptionalParent(key: "owner_user_id") var owner: UserModel?
    @Field(key: "title") var title: String
    @OptionalField(key: "description") var description: String?
    @Field(key: "servings") var servings: Int
    @OptionalField(key: "prep_minutes") var prepMinutes: Int?
    @OptionalField(key: "cook_minutes") var cookMinutes: Int?
    @Field(key: "instructions") var instructions: [String]
    @OptionalField(key: "cuisine") var cuisine: String?
    @OptionalField(key: "dish_type") var dishType: String?
    @OptionalField(key: "main_ingredient") var mainIngredient: String?
    @Field(key: "dietary_tags") var dietaryTags: [String]
    @Field(key: "visibility") var visibility: String
    @Field(key: "is_imported") var isImported: Bool
    @OptionalField(key: "source_url") var sourceURL: String?
    @OptionalField(key: "source_url_hash") var sourceURLHash: String?
    @OptionalField(key: "source_site") var sourceSite: String?
    @OptionalField(key: "source_attribution") var sourceAttribution: String?
    @OptionalField(key: "imported_at") var importedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    @Children(for: \.$recipe) var ingredients: [RecipeIngredientModel]
    @Children(for: \.$recipe) var images: [RecipeImageModel]

    init() {}

    init(
        id: UUID? = nil,
        ownerID: UUID?,
        title: String,
        description: String? = nil,
        servings: Int,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        instructions: [String],
        cuisine: String? = nil,
        dishType: String? = nil,
        mainIngredient: String? = nil,
        dietaryTags: [String] = [],
        visibility: String = "private",
        isImported: Bool = false,
        sourceURL: String? = nil,
        sourceURLHash: String? = nil
    ) {
        self.id = id
        self.$owner.id = ownerID
        self.title = title
        self.description = description
        self.servings = servings
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.instructions = instructions
        self.cuisine = cuisine
        self.dishType = dishType
        self.mainIngredient = mainIngredient
        self.dietaryTags = dietaryTags
        self.visibility = visibility
        self.isImported = isImported
        self.sourceURL = sourceURL
        self.sourceURLHash = sourceURLHash
    }
}

final class RecipeIngredientModel: Model, @unchecked Sendable {
    static let schema = "recipe_ingredients"

    @ID(key: .id) var id: UUID?
    @Parent(key: "recipe_id") var recipe: RecipeModel
    @Field(key: "name") var name: String
    @Field(key: "normalized_name") var normalizedName: String
    @OptionalField(key: "quantity") var quantity: Decimal?
    @OptionalField(key: "unit") var unit: String?
    @OptionalField(key: "note") var note: String?
    @OptionalField(key: "category") var category: String?
    @Field(key: "sort_order") var sortOrder: Int

    init() {}

    init(
        id: UUID = UUID(),
        recipeID: UUID,
        name: String,
        normalizedName: String,
        quantity: Decimal?,
        unit: String?,
        note: String?,
        category: String?,
        sortOrder: Int
    ) {
        self.id = id
        self.$recipe.id = recipeID
        self.name = name
        self.normalizedName = normalizedName
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.category = category
        self.sortOrder = sortOrder
    }

    func dto() -> IngredientDTO {
        IngredientDTO(
            id: id ?? UUID(),
            name: name,
            quantity: quantity,
            unit: unit,
            note: note,
            category: category.flatMap(IngredientCategory.init(rawValue:)) ?? .other
        )
    }
}

final class RecipeImageModel: Model, @unchecked Sendable {
    static let schema = "recipe_images"

    @ID(key: .id) var id: UUID?
    @Parent(key: "recipe_id") var recipe: RecipeModel
    @Field(key: "storage_key") var storageKey: String
    @OptionalField(key: "source_url") var sourceURL: String?
    @Field(key: "sort_order") var sortOrder: Int
    @OptionalField(key: "width") var width: Int?
    @OptionalField(key: "height") var height: Int?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(recipeID: UUID, storageKey: String, sourceURL: String? = nil, sortOrder: Int = 0) {
        self.$recipe.id = recipeID
        self.storageKey = storageKey
        self.sourceURL = sourceURL
        self.sortOrder = sortOrder
    }
}

final class RecipeShareModel: Model, @unchecked Sendable {
    static let schema = "recipe_shares"

    @ID(key: .id) var id: UUID?
    @Parent(key: "recipe_id") var recipe: RecipeModel
    @Parent(key: "shared_with_user_id") var sharedWith: UserModel
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?

    init() {}

    init(recipeID: UUID, sharedWithUserID: UUID) {
        self.$recipe.id = recipeID
        self.$sharedWith.id = sharedWithUserID
    }
}

final class RecipeFavoriteModel: Model, @unchecked Sendable {
    static let schema = "recipe_favorites"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "recipe_id") var recipe: RecipeModel
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, recipeID: UUID) {
        self.$user.id = userID
        self.$recipe.id = recipeID
    }
}

final class RecipeBlockModel: Model, @unchecked Sendable {
    static let schema = "recipe_blocks"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "recipe_id") var recipe: RecipeModel
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, recipeID: UUID) {
        self.$user.id = userID
        self.$recipe.id = recipeID
    }
}

final class RecipePersonalizationModel: Model, @unchecked Sendable {
    static let schema = "recipe_personalizations"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "recipe_id") var recipe: RecipeModel
    @OptionalField(key: "title") var title: String?
    @OptionalField(key: "servings") var servings: Int?
    @OptionalField(key: "instructions") var instructions: [String]?
    @OptionalField(key: "ingredients") var ingredients: [IngredientDTO]?
    @OptionalField(key: "notes") var notes: String?
    @Field(key: "updated_at") var updatedAt: Date

    init() {}

    init(userID: UUID, recipeID: UUID) {
        self.$user.id = userID
        self.$recipe.id = recipeID
        self.updatedAt = Date()
    }

    func dto() -> PersonalizationDTO {
        PersonalizationDTO(
            title: title,
            servings: servings,
            instructions: instructions,
            ingredients: ingredients,
            notes: notes,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Imports

final class ImportJobModel: Model, @unchecked Sendable {
    static let schema = "import_jobs"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "url") var url: String
    @Field(key: "url_hash") var urlHash: String
    @Field(key: "status") var status: String
    @OptionalParent(key: "recipe_id") var recipe: RecipeModel?
    @OptionalField(key: "error_code") var errorCode: String?
    @OptionalField(key: "error_message") var errorMessage: String?
    @Field(key: "attempts") var attempts: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @OptionalField(key: "completed_at") var completedAt: Date?

    init() {}

    init(userID: UUID, url: String, urlHash: String, status: String = "queued") {
        self.$user.id = userID
        self.url = url
        self.urlHash = urlHash
        self.status = status
        self.attempts = 0
    }

    func dto() throws -> ImportJobDTO {
        ImportJobDTO(
            id: try requireID(),
            status: ImportJobStatus(rawValue: status) ?? .queued,
            sourceURL: URL(string: url) ?? URL(string: "https://invalid.local")!,
            recipeID: $recipe.id,
            errorCode: errorCode,
            errorMessage: errorMessage,
            createdAt: createdAt ?? Date(),
            updatedAt: updatedAt ?? Date()
        )
    }
}

// MARK: - Planning

final class MealPlanModel: Model, @unchecked Sendable {
    static let schema = "meal_plans"

    @ID(key: .id) var id: UUID?
    @Parent(key: "owner_user_id") var owner: UserModel
    @Field(key: "name") var name: String
    @Field(key: "start_date") var startDate: String
    @Field(key: "day_count") var dayCount: Int
    @Field(key: "slots") var slots: [String]
    @Field(key: "rules") var rules: PlanRules
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @OptionalField(key: "last_synced_by_user_id") var lastSyncedByUserID: UUID?
    @OptionalField(key: "last_synced_at") var lastSyncedAt: Date?

    @Children(for: \.$plan) var members: [PlanMemberModel]

    init() {}

    init(
        id: UUID? = nil,
        ownerID: UUID,
        name: String,
        startDate: CalendarDate,
        dayCount: Int,
        slots: [MealSlot],
        rules: PlanRules
    ) {
        self.id = id
        self.$owner.id = ownerID
        self.name = name
        self.startDate = startDate.isoString
        self.dayCount = dayCount
        self.slots = slots.map(\.rawValue)
        self.rules = rules
    }

    var calendarStartDate: CalendarDate {
        CalendarDate(isoString: startDate) ?? .reference
    }

    var mealSlots: [MealSlot] {
        slots.compactMap(MealSlot.init(rawValue:))
    }
}

final class PlanMemberModel: Model, @unchecked Sendable {
    static let schema = "plan_members"

    @ID(key: .id) var id: UUID?
    @Parent(key: "plan_id") var plan: MealPlanModel
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "role") var role: String
    @OptionalField(key: "invited_by_user_id") var invitedByUserID: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?

    init() {}

    init(planID: UUID, userID: UUID, role: PlanRole, invitedBy: UUID? = nil) {
        self.$plan.id = planID
        self.$user.id = userID
        self.role = role.rawValue
        self.invitedByUserID = invitedBy
    }

    var planRole: PlanRole {
        PlanRole(rawValue: role) ?? .viewer
    }
}

final class PlanDocumentModel: Model, @unchecked Sendable {
    static let schema = "plan_documents"

    @ID(custom: "plan_id", generatedBy: .user) var id: UUID?
    @Field(key: "schema_version") var schemaVersion: Int
    @Field(key: "state") var state: PlanDocument
    @Field(key: "state_hash") var stateHash: String
    @Field(key: "updated_at") var updatedAt: Date

    init() {}

    init(planID: UUID, state: PlanDocument) {
        self.id = planID
        self.schemaVersion = state.schemaVersion
        self.state = state
        self.stateHash = state.stateHash
        self.updatedAt = Date()
    }
}

final class ShoppingListDocumentModel: Model, @unchecked Sendable {
    static let schema = "shopping_list_documents"

    @ID(custom: "plan_id", generatedBy: .user) var id: UUID?
    @Field(key: "schema_version") var schemaVersion: Int
    @Field(key: "state") var state: ShoppingListDocument
    @Field(key: "state_hash") var stateHash: String
    @Field(key: "source_plan_hash") var sourcePlanHash: String
    @Field(key: "generated_at") var generatedAt: Date
    @Field(key: "updated_at") var updatedAt: Date

    init() {}

    init(planID: UUID, state: ShoppingListDocument, generatedAt: Date = Date()) {
        self.id = planID
        self.schemaVersion = state.schemaVersion
        self.state = state
        self.stateHash = state.stateHash
        self.sourcePlanHash = state.sourcePlanHash.value
        self.generatedAt = generatedAt
        self.updatedAt = Date()
    }
}

// MARK: - Audit

final class AuditLogModel: Model, @unchecked Sendable {
    static let schema = "audit_logs"

    @ID(key: .id) var id: UUID?
    @OptionalField(key: "actor_user_id") var actorUserID: UUID?
    @Field(key: "action") var action: String
    @Field(key: "entity_type") var entityType: String
    @OptionalField(key: "entity_id") var entityID: UUID?
    @Field(key: "metadata") var metadata: [String: String]
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(actorUserID: UUID?, action: String, entityType: String, entityID: UUID?, metadata: [String: String] = [:]) {
        self.actorUserID = actorUserID
        self.action = action
        self.entityType = entityType
        self.entityID = entityID
        self.metadata = metadata
    }
}
