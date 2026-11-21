import Fluent
import MealPlannerCore
import SQLKit
import Vapor

struct CreateUsers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .id()
            .field("email", .string, .required)
            .field("display_name", .string, .required)
            .field("apple_subject_id", .string)
            .field("is_admin", .bool, .required, .sql(.default(false)))
            .field("is_disabled", .bool, .required, .sql(.default(false)))
            .field("measurement_system", .string, .required, .sql(.default("metric")))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "email")
            .unique(on: "apple_subject_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users").delete()
    }
}

struct CreateUserDevices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_devices")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("platform", .string, .required)
            .field("last_seen_at", .datetime, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_devices").delete()
    }
}

struct CreateMagicLinkTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("magic_link_tokens")
            .id()
            .field("email", .string, .required)
            .field("user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("token_hash", .string, .required)
            .field("client", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("consumed_at", .datetime)
            .field("created_at", .datetime)
            .field("request_ip", .string)
            .field("user_agent", .string)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("magic_link_tokens").delete()
    }
}

struct CreateRefreshTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("refresh_tokens")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("device_id", .uuid, .required, .references("user_devices", "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("refresh_tokens").delete()
    }
}

struct CreateAdminSessions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("admin_sessions")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("session_token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "session_token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("admin_sessions").delete()
    }
}

struct CreateFriendTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("friend_requests")
            .id()
            .field("from_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("to_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .field("responded_at", .datetime)
            .unique(on: "from_user_id", "to_user_id", "status")
            .create()

        try await database.schema("friendships")
            .id()
            .field("user_a_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("user_b_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "user_a_id", "user_b_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("friendships").delete()
        try await database.schema("friend_requests").delete()
    }
}

struct CreateRecipes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("recipes")
            .id()
            .field("owner_user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("title", .string, .required)
            .field("description", .string)
            .field("servings", .int, .required)
            .field("prep_minutes", .int)
            .field("cook_minutes", .int)
            .field("instructions", .array(of: .string), .required)
            .field("cuisine", .string)
            .field("dish_type", .string)
            .field("main_ingredient", .string)
            .field("dietary_tags", .array(of: .string), .required)
            .field("visibility", .string, .required)
            .field("is_imported", .bool, .required, .sql(.default(false)))
            .field("source_url", .string)
            .field("source_url_hash", .string)
            .field("source_site", .string)
            .field("source_attribution", .string)
            .field("imported_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("deleted_at", .datetime)
            .unique(on: "source_url_hash")
            .create()

        try await database.schema("recipe_ingredients")
            .id()
            .field("recipe_id", .uuid, .required, .references("recipes", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("normalized_name", .string, .required)
            .field("quantity", .custom(SQLRaw("NUMERIC(12,3)")))
            .field("unit", .string)
            .field("note", .string)
            .field("category", .string)
            .field("sort_order", .int, .required)
            .create()

        try await database.schema("recipe_images")
            .id()
            .field("recipe_id", .uuid, .required, .references("recipes", "id", onDelete: .cascade))
            .field("storage_key", .string, .required)
            .field("source_url", .string)
            .field("sort_order", .int, .required)
            .field("width", .int)
            .field("height", .int)
            .field("created_at", .datetime)
            .create()

        try await database.schema("recipe_shares")
            .id()
            .field("recipe_id", .uuid, .required, .references("recipes", "id", onDelete: .cascade))
            .field("shared_with_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("revoked_at", .datetime)
            .unique(on: "recipe_id", "shared_with_user_id")
            .create()

        try await database.schema("recipe_favorites")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("recipe_id", .uuid, .required, .references("recipes", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "user_id", "recipe_id")
            .create()

        try await database.schema("recipe_blocks")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("recipe_id", .uuid, .required, .references("recipes", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "user_id", "recipe_id")
            .create()

        try await database.schema("recipe_personalizations")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("recipe_id", .uuid, .required, .references("recipes", "id", onDelete: .cascade))
            .field("title", .string)
            .field("servings", .int)
            .field("instructions", .array(of: .string))
            .field("ingredients", .json)
            .field("notes", .string)
            .field("updated_at", .datetime, .required)
            .unique(on: "user_id", "recipe_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("recipe_personalizations").delete()
        try await database.schema("recipe_blocks").delete()
        try await database.schema("recipe_favorites").delete()
        try await database.schema("recipe_shares").delete()
        try await database.schema("recipe_images").delete()
        try await database.schema("recipe_ingredients").delete()
        try await database.schema("recipes").delete()
    }
}

struct CreateImportJobs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("import_jobs")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("url", .string, .required)
            .field("url_hash", .string, .required)
            .field("status", .string, .required)
            .field("recipe_id", .uuid, .references("recipes", "id", onDelete: .setNull))
            .field("error_code", .string)
            .field("error_message", .string)
            .field("attempts", .int, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("completed_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("import_jobs").delete()
    }
}

struct CreatePlanningTables: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("meal_plans")
            .id()
            .field("owner_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("start_date", .string, .required)
            .field("day_count", .int, .required)
            .field("slots", .array(of: .string), .required)
            .field("rules", .json, .required)
            .field("deleted_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("last_synced_by_user_id", .uuid)
            .field("last_synced_at", .datetime)
            .create()

        try await database.schema("plan_members")
            .id()
            .field("plan_id", .uuid, .required, .references("meal_plans", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("role", .string, .required)
            .field("invited_by_user_id", .uuid)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("revoked_at", .datetime)
            .create()

        try await database.schema("plan_documents")
            .field("plan_id", .uuid, .identifier(auto: false), .references("meal_plans", "id", onDelete: .cascade))
            .field("schema_version", .int, .required)
            .field("state", .json, .required)
            .field("state_hash", .string, .required)
            .field("updated_at", .datetime, .required)
            .create()

        try await database.schema("shopping_list_documents")
            .field("plan_id", .uuid, .identifier(auto: false), .references("meal_plans", "id", onDelete: .cascade))
            .field("schema_version", .int, .required)
            .field("state", .json, .required)
            .field("state_hash", .string, .required)
            .field("source_plan_hash", .string, .required)
            .field("generated_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("shopping_list_documents").delete()
        try await database.schema("plan_documents").delete()
        try await database.schema("plan_members").delete()
        try await database.schema("meal_plans").delete()
    }
}

struct CreateAuditLogs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("audit_logs")
            .id()
            .field("actor_user_id", .uuid)
            .field("action", .string, .required)
            .field("entity_type", .string, .required)
            .field("entity_id", .uuid)
            .field("metadata", .json, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("audit_logs").delete()
    }
}
