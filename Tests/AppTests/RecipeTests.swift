import Foundation
import MealPlannerCore
import Testing
import XCTVapor
import Vapor
@testable import App

@Suite(.serialized)
struct RecipeTests {
    @Test("Creates, reads and lists recipes")
    func crud() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)

        let created = try await createRecipe(app, token: user)
        #expect(created.title == "Test Soup")
        #expect(created.ingredients.count == 1)

        let fetched: RecipeDTO = try await apiRequest(
            app, .GET, "/recipes/\(created.id.uuidString)", headers: authHeaders(user)
        )
        #expect(fetched.id == created.id)

        let list: RecipeListResponse = try await apiRequest(
            app, .GET, "/recipes?q=soup", headers: authHeaders(user)
        )
        #expect(list.items.count == 1)

        try await apiStatus(
            app, .DELETE, "/recipes/\(created.id.uuidString)",
            headers: authHeaders(user), expected: .noContent
        )
        try await apiStatus(
            app, .GET, "/recipes/\(created.id.uuidString)",
            headers: authHeaders(user), expected: .notFound
        )
        try await app.asyncShutdown()
    
        })}

    @Test("A stranger cannot view a private recipe")
    func privateAccess() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let owner = try await signIn(app, email: "owner@example.com")
        let stranger = try await signIn(app, email: "stranger@example.com")
        let recipe = try await createRecipe(app, token: owner)

        try await apiStatus(
            app, .GET, "/recipes/\(recipe.id.uuidString)",
            headers: authHeaders(stranger), expected: .notFound
        )
        try await app.asyncShutdown()
    
        })}

    @Test("Friends can view shared recipes")
    func sharedAccess() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let owner = try await signIn(app, email: "owner@example.com")
        let friend = try await signIn(app, email: "friend@example.com")

        struct FriendBody: Encodable { var email: String }
        try await apiStatus(
            app, .POST, "/friends",
            headers: authHeaders(friend),
            body: FriendBody(email: "owner@example.com"),
            expected: .accepted
        )
        try await apiStatus(
            app, .POST, "/friends/\(friend.user.id.uuidString)/accept",
            headers: authHeaders(owner)
        )

        let recipe = try await createRecipe(app, token: owner)
        struct ShareBody: Encodable { var userID: UUID }
        try await apiStatus(
            app, .POST, "/recipes/\(recipe.id.uuidString)/share",
            headers: authHeaders(owner),
            body: ShareBody(userID: friend.user.id)
        )

        let fetched: RecipeDTO = try await apiRequest(
            app, .GET, "/recipes/\(recipe.id.uuidString)", headers: authHeaders(friend)
        )
        #expect(fetched.id == recipe.id)
        try await app.asyncShutdown()
    
        })}

    @Test("Favorites and blocks work")
    func favoritesAndBlocks() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        let recipe = try await createRecipe(app, token: user)

        try await apiStatus(app, .POST, "/recipes/\(recipe.id.uuidString)/favorite", headers: authHeaders(user))
        try await apiStatus(app, .POST, "/recipes/\(recipe.id.uuidString)/block", headers: authHeaders(user))

        let list: RecipeListResponse = try await apiRequest(app, .GET, "/recipes?favorites=true", headers: authHeaders(user))
        #expect(list.items.count == 0)

        let withBlocked: RecipeListResponse = try await apiRequest(app, .GET, "/recipes?excludeBlocked=false", headers: authHeaders(user))
        #expect(withBlocked.items.count == 1)
        #expect(withBlocked.items.first?.isFavorite == true)
        #expect(withBlocked.items.first?.isBlocked == true)
        try await app.asyncShutdown()
    
        })}

    @Test("Personalization does not modify the canonical recipe")
    func personalization() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        let recipe = try await createRecipe(app, token: user)

        struct Body: Encodable { var title: String; var servings: Int }
        let personalized: RecipeDTO = try await apiRequest(
            app, .PUT, "/recipes/\(recipe.id.uuidString)/personalization",
            headers: authHeaders(user),
            body: Body(title: "My version", servings: 4)
        )
        #expect(personalized.title == "Test Soup")
        #expect(personalized.personalization?.title == "My version")
        #expect(personalized.effective().title == "My version")
        #expect(personalized.effective().servings == 4)
        try await app.asyncShutdown()
    
        })}

    @Test("Imported recipes are canonically immutable")
    func importedImmutable() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)

        app.importService = ImportService(
            db: app.db,
            fetcher: FakeFetcher(),
            extractor: FakeExtractor(),
            imageStorage: FakeImageStorage()
        )

        struct ImportBody: Encodable { var url: String }
        let started: RecipeImportResponse = try await apiRequest(
            app, .POST, "/recipes/import",
            headers: authHeaders(user),
            body: ImportBody(url: "https://example.com/recipes/soup")
        )
        let result: RecipeImportResponse = try await apiRequest(
            app, .POST, "/recipes/import/\(started.jobID.uuidString)/run",
            headers: authHeaders(user)
        )
        #expect(result.status == .succeeded)

        let imported: RecipeListResponse = try await apiRequest(
            app, .GET, "/recipes", headers: authHeaders(user)
        )
        #expect(imported.items.count == 1)
        #expect(imported.items.first?.isImported == true)
        #expect(imported.items.first?.visibility == .public)

        let duplicate: RecipeImportResponse = try await apiRequest(
            app, .POST, "/recipes/import",
            headers: authHeaders(user),
            body: ImportBody(url: "https://example.com/recipes/soup?utm_source=x")
        )
        #expect(duplicate.status == .duplicate)
        try await app.asyncShutdown()
    
        })}

    @Test("SSRF URLs are rejected")
    func ssrf() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)

        struct ImportBody: Encodable { var url: String }
        try await apiStatus(
            app, .POST, "/recipes/import",
            headers: authHeaders(user),
            body: ImportBody(url: "http://127.0.0.1/admin"),
            expected: .badRequest
        )
        try await app.asyncShutdown()
    
        })}
}
