import Fluent
import Foundation
import MealPlannerCore
import Vapor

// MARK: - Form payloads

private struct AdminUserForm: Content {
    var email: String
    var displayName: String
    var isAdmin: Bool?
}

private struct AdminRecipeForm: Content {
    var title: String
    var description: String?
    var servings: Int
    var prepMinutes: Int?
    var cookMinutes: Int?
    var cuisine: String?
    var dishType: String?
    var mainIngredient: String?
    var dietaryTags: String?
    var visibility: String
    var instructions: String
    var ingredients: String
}

private struct AdminImportForm: Content {
    var url: String
    var runNow: Bool?
}

// MARK: - Additional admin pages

extension AdminController {
    func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func redirect(_ path: String) -> Response {
        Response(status: .found, headers: ["Location": path], body: .empty)
    }

    private func checkboxes(name: String, selected: Set<String>, all: [String]) -> String {
        all.map { value in
            let checked = selected.contains(value) ? " checked" : ""
            return "<label><input type='checkbox' name='\(name)' value='\(escape(value))'\(checked)> \(escape(value.capitalized))</label> "
        }.joined()
    }

    private func parseIngredients(_ raw: String) -> [IngredientDTO] {
        raw.split(whereSeparator: \.isNewline).enumerated().compactMap { _, line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            let quantity = parts.count > 1 ? Decimal(string: parts[1]) : nil
            let unit = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            let category = parts.count > 3 ? (IngredientCategory(rawValue: parts[3]) ?? .other) : .other
            let note = parts.count > 4 && !parts[4].isEmpty ? parts[4] : nil
            return IngredientDTO(
                id: UUID(),
                name: name,
                quantity: quantity,
                unit: unit,
                note: note,
                category: category
            )
        }
    }

    private func parseLines(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func ingredientsText(_ ingredients: [IngredientDTO]) -> String {
        ingredients.map { item in
            [
                item.name,
                item.quantity?.description ?? "",
                item.unit ?? "",
                item.category.rawValue,
                item.note ?? "",
            ].joined(separator: " | ")
        }.joined(separator: "\n")
    }

    private func recipeForm(
        action: String,
        csrf: String,
        button: String,
        recipe: RecipeModel? = nil,
        ingredients: [IngredientDTO] = []
    ) -> String {
        let title = recipe?.title ?? ""
        let description = recipe?.description ?? ""
        let servings = recipe?.servings ?? 2
        let prep = recipe?.prepMinutes.map(String.init) ?? ""
        let cook = recipe?.cookMinutes.map(String.init) ?? ""
        let cuisine = recipe?.cuisine ?? ""
        let dishType = recipe?.dishType ?? ""
        let main = recipe?.mainIngredient ?? ""
        let tags = (recipe?.dietaryTags ?? []).joined(separator: ", ")
        let visibility = recipe?.visibility ?? "private"
        let instructions = (recipe?.instructions ?? []).joined(separator: "\n")
        let ingredientsValue = ingredientsText(ingredients)

        return """
        <form method='post' action='\(action)'>
        <input type='hidden' name='csrf' value='\(csrf)'>
        <p><label>Title <input name='title' value='\(escape(title))' required></label></p>
        <p><label>Description <input name='description' value='\(escape(description))'></label></p>
        <p><label>Servings <input type='number' name='servings' min='1' value='\(servings)' required></label></p>
        <p><label>Prep minutes <input type='number' name='prepMinutes' min='0' value='\(prep)'></label>
        <label>Cook minutes <input type='number' name='cookMinutes' min='0' value='\(cook)'></label></p>
        <p><label>Cuisine <input name='cuisine' value='\(escape(cuisine))'></label>
        <label>Dish type <input name='dishType' value='\(escape(dishType))'></label>
        <label>Main ingredient <input name='mainIngredient' value='\(escape(main))'></label></p>
        <p><label>Dietary tags (comma separated) <input name='dietaryTags' value='\(escape(tags))'></label></p>
        <p><label>Visibility <select name='visibility'>
        <option value='private'\(visibility == "private" ? " selected" : "")>Private</option>
        <option value='public'\(visibility == "public" ? " selected" : "")>Public</option>
        </select></label></p>
        <p><label>Instructions (one per line)<br>
        <textarea name='instructions' rows='6' cols='60' required>\(escape(instructions))</textarea></label></p>
        <p><label>Ingredients (one per line: name | quantity | unit | category | note)<br>
        <textarea name='ingredients' rows='6' cols='60'>\(escape(ingredientsValue))</textarea></label></p>
        <p><button type='submit'>\(button)</button></p>
        </form>
        """
    }

    private func apply(_ form: AdminRecipeForm, to recipe: RecipeModel) {
        recipe.title = form.title.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.description = form.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.servings = form.servings
        recipe.prepMinutes = form.prepMinutes
        recipe.cookMinutes = form.cookMinutes
        recipe.cuisine = form.cuisine?.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.dishType = form.dishType?.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.mainIngredient = form.mainIngredient?.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.dietaryTags = parseLines(form.dietaryTags ?? "").map { $0.lowercased() }
            .compactMap { $0.split(separator: ",").map(String.init) }.flatMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        recipe.visibility = form.visibility == "public" ? "public" : "private"
        recipe.instructions = parseLines(form.instructions)
        recipe.updatedAt = Date()
    }

    private func replaceIngredients(_ ingredients: [IngredientDTO], recipeID: UUID, on db: any Database) async throws {
        let existing = try await RecipeIngredientModel.query(on: db)
            .filter(\.$recipe.$id == recipeID)
            .all()
        for item in existing {
            try await item.delete(force: true, on: db)
        }
        for (index, item) in ingredients.enumerated() {
            try await RecipeIngredientModel(
                id: item.id,
                recipeID: recipeID,
                name: item.name,
                normalizedName: IngredientNormalizer.normalize(item.name),
                quantity: item.quantity,
                unit: item.unit,
                note: item.note,
                category: item.category.rawValue,
                sortOrder: index
            ).save(on: db)
        }
    }

    // MARK: Users

    @Sendable
    func newUser(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        return page("New User", form(
            action: "/admin/users",
            csrf: csrf(request),
            button: "Create user",
            extra: """
            <p><label>Email <input type='email' name='email' required></label></p>
            <p><label>Display name <input name='displayName' required></label></p>
            <p><label><input type='checkbox' name='isAdmin' value='true'> Administrator</label></p>
            """
        ))
    }

    @Sendable
    func createUser(_ request: Request) async throws -> Response {
        let actor = try request.requireAdmin()
        try validateCSRF(request)
        let body = try request.content.decode(AdminUserForm.self)
        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = body.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !name.isEmpty else {
            throw Abort(.badRequest, reason: "A valid email and display name are required.")
        }
        if try await UserModel.query(on: request.db).filter(\.$email == email).first() != nil {
            throw Abort(.badRequest, reason: "A user with that email already exists.")
        }

        let user = UserModel(email: email, displayName: name, isAdmin: body.isAdmin == true)
        try await user.save(on: request.db)
        try await AuditLogModel(
            actorUserID: actor,
            action: "admin.user.create",
            entityType: "user",
            entityID: user.id,
            metadata: ["email": email]
        ).save(on: request.db)
        return redirect("/admin/users")
    }

    // MARK: Recipes

    @Sendable
    func recipes(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        let recipes = try await RecipeModel.query(on: request.db).sort(\.$title).all()
        var rows = ""
        for recipe in recipes {
            let id = recipe.id?.uuidString ?? ""
            let edit = "<a href='/admin/recipes/\(id)/edit'>Edit</a>"
            let deleteForm = form(
                action: "/admin/recipes/\(id)/delete",
                csrf: csrf(request),
                button: "Delete",
                extra: ""
            )
            rows += """
            <tr><td>\(escape(recipe.title))</td><td>\(escape(recipe.visibility))</td>
            <td>\(recipe.isImported ? "imported" : "user")</td><td>\(edit)</td><td>\(deleteForm)</td></tr>
            """
        }
        let createLink = "<p><a href='/admin/recipes/new'>New recipe</a></p>"
        return page("Recipes", createLink + """
        <table><tr><th>Title</th><th>Visibility</th><th>Source</th><th></th><th></th></tr>\(rows)</table>
        """)
    }

    @Sendable
    func newRecipe(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        return page("New Recipe", recipeForm(
            action: "/admin/recipes",
            csrf: csrf(request),
            button: "Create recipe"
        ))
    }

    @Sendable
    func editRecipe(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        guard let id = request.parameters.get("recipeID", as: UUID.self),
              let recipe = try await RecipeModel.find(id, on: request.db)
        else { throw Abort(.notFound) }

        let ingredients = try await RecipeIngredientModel.query(on: request.db)
            .filter(\.$recipe.$id == id)
            .sort(\.$sortOrder)
            .all()
            .map { $0.dto() }

        let notice = recipe.isImported
            ? "<p class='error'>Imported recipes are canonically immutable. Only delete is allowed.</p>"
            : ""
        return page("Edit Recipe", notice + recipeForm(
            action: "/admin/recipes/\(id.uuidString)",
            csrf: csrf(request),
            button: "Save recipe",
            recipe: recipe,
            ingredients: ingredients
        ))
    }

    @Sendable
    func createRecipe(_ request: Request) async throws -> Response {
        let actor = try request.requireAdmin()
        try validateCSRF(request)
        let body = try request.content.decode(AdminRecipeForm.self)
        guard !body.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.servings > 0 else {
            throw Abort(.badRequest, reason: "Title and positive servings are required.")
        }
        let ingredients = parseIngredients(body.ingredients)
        guard !ingredients.isEmpty else {
            throw Abort(.badRequest, reason: "Add at least one ingredient.")
        }

        let recipe = RecipeModel(
            ownerID: actor,
            title: body.title,
            description: body.description,
            servings: body.servings,
            prepMinutes: body.prepMinutes,
            cookMinutes: body.cookMinutes,
            instructions: parseLines(body.instructions),
            cuisine: body.cuisine,
            dishType: body.dishType,
            mainIngredient: body.mainIngredient,
            dietaryTags: [],
            visibility: body.visibility == "public" ? "public" : "private"
        )
        apply(body, to: recipe)
        try await recipe.save(on: request.db)
        let recipeID = try recipe.requireID()
        try await replaceIngredients(ingredients, recipeID: recipeID, on: request.db)
        try await AuditLogModel(
            actorUserID: actor,
            action: "admin.recipe.create",
            entityType: "recipe",
            entityID: recipeID
        ).save(on: request.db)
        return redirect("/admin/recipes")
    }

    @Sendable
    func updateRecipe(_ request: Request) async throws -> Response {
        let actor = try request.requireAdmin()
        try validateCSRF(request)
        guard let id = request.parameters.get("recipeID", as: UUID.self),
              let recipe = try await RecipeModel.find(id, on: request.db)
        else { throw Abort(.notFound) }
        guard !recipe.isImported else {
            throw Abort(.badRequest, reason: "Imported recipes cannot be edited.")
        }

        let body = try request.content.decode(AdminRecipeForm.self)
        guard !body.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.servings > 0 else {
            throw Abort(.badRequest, reason: "Title and positive servings are required.")
        }
        let ingredients = parseIngredients(body.ingredients)
        guard !ingredients.isEmpty else {
            throw Abort(.badRequest, reason: "Add at least one ingredient.")
        }

        apply(body, to: recipe)
        try await recipe.save(on: request.db)
        try await replaceIngredients(ingredients, recipeID: id, on: request.db)
        try await AuditLogModel(
            actorUserID: actor,
            action: "admin.recipe.update",
            entityType: "recipe",
            entityID: id
        ).save(on: request.db)
        return redirect("/admin/recipes")
    }

    @Sendable
    func deleteRecipe(_ request: Request) async throws -> Response {
        let actor = try request.requireAdmin()
        try validateCSRF(request)
        guard let id = request.parameters.get("recipeID", as: UUID.self),
              let recipe = try await RecipeModel.find(id, on: request.db)
        else { throw Abort(.notFound) }
        try await recipe.delete(on: request.db)
        try await AuditLogModel(
            actorUserID: actor,
            action: "admin.recipe.delete",
            entityType: "recipe",
            entityID: id
        ).save(on: request.db)
        return redirect("/admin/recipes")
    }

    // MARK: Imports

    @Sendable
    func newImport(_ request: Request) async throws -> Response {
        _ = try request.requireAdmin()
        return page("New Import", form(
            action: "/admin/imports",
            csrf: csrf(request),
            button: "Create import",
            extra: """
            <p><label>Recipe URL <input type='url' name='url' required></label></p>
            <p><label><input type='checkbox' name='runNow' value='true'> Run immediately</label></p>
            """
        ))
    }

    @Sendable
    func createImport(_ request: Request) async throws -> Response {
        let actor = try request.requireAdmin()
        try validateCSRF(request)
        let body = try request.content.decode(AdminImportForm.self)
        guard URLNormalizer.normalize(body.url) != nil else {
            throw Abort(.badRequest, reason: "Enter a valid http(s) recipe URL.")
        }

        let result = try await request.application.importService.start(
            userID: actor,
            rawURL: body.url
        )
        var job = result
        if body.runNow == true && result.status == .queued {
            job = try await request.application.importService.process(jobID: result.jobID)
        }
        try await AuditLogModel(
            actorUserID: actor,
            action: "admin.import.create",
            entityType: "import_job",
            entityID: result.jobID,
            metadata: ["url": body.url, "status": job.status.rawValue]
        ).save(on: request.db)
        return page("Import Created", """
        <p>Status: \(job.status.rawValue)</p>
        <p><a href='/admin/imports'>Back to imports</a></p>
        """)
    }
}
