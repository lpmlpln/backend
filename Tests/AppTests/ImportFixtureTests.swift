import Foundation
import MealPlannerCore
import Testing
import Vapor
import XCTVapor
@testable import App

private struct StaticExtractor: RecipeExtracting {
    let draft: ImportedRecipeDraft

    func extract(from page: FetchedPage) async throws -> ImportedRecipeDraft {
        var result = OpenRouterRecipeExtractor.applyStructuredFallback(to: draft, html: page.html)
        result.sourceURL = page.url
        return result
    }
}

@Suite("Regression fixtures from real reports")
struct ImportFixtureTests {
    private static let reportURL = "https://verdegusto.it/en/ricette/spring-cutlets-with-arugula-and-tomatoes-spring-recipe"

    private func fixture(_ relativePath: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(relativePath)
        return try Data(contentsOf: url)
    }

    /// The exact report: real page HTML plus the completion shapes that can
    /// trigger `missingIngredients` must still produce all nine ingredients.
    @Test("VerdeGusto import succeeds at the HTTP layer")
    func verdegustoImport() async throws {
        for completionName in [
            "verdegusto-spring-cutlets.json",
            "verdegusto-blank-ingredients.json",
            "verdegusto-partial-ingredients.json",
        ] {
            try await testGate.run(TestBody {
            let app = try await makeTestApp()
            try await resetDatabase(app)
            let user = try await signIn(app)

            let html = String(decoding: try fixture("recipes/verdegusto-spring-cutlets.html"), as: UTF8.self)
            let completion = try fixture("openrouter/\(completionName)")
            let draft = try OpenRouterRecipeExtractor.parseCompletion(completion)

            app.importService = ImportService(
                db: app.db,
                fetcher: FakeFetcher(html: html),
                extractor: StaticExtractor(draft: draft),
                imageStorage: FakeImageStorage()
            )

            struct ImportBody: Encodable { var url: String }
            let started: RecipeImportResponse = try await apiRequest(
                app, .POST, "/recipes/import",
                headers: authHeaders(user),
                body: ImportBody(url: Self.reportURL)
            )
            let result: RecipeImportResponse = try await apiRequest(
                app, .POST, "/recipes/import/\(started.jobID.uuidString)/run",
                headers: authHeaders(user)
            )
            #expect(result.status == .succeeded)

            let list: RecipeListResponse = try await apiRequest(app, .GET, "/recipes", headers: authHeaders(user))
            let recipe = try #require(list.items.first)
            let detail: RecipeDTO = try await apiRequest(
                app, .GET, "/recipes/\(recipe.id.uuidString)", headers: authHeaders(user)
            )
            #expect(detail.title == "Spring Cutlets with Arugula and Tomatoes")
            #expect(detail.ingredients.count == 9)
            #expect(detail.instructions.count == 8)
            #expect(detail.instructions.first?.contains("Beat the eggs") == true)
            #expect(detail.servings == 4)
            #expect(detail.isImported)
            #expect(detail.visibility == .public)

            try await app.asyncShutdown()
        })
        }
    }

    /// Opt-in: the live page can change without a code change. Run locally or
    /// nightly with `RUN_LIVE_IMPORT_TESTS=1 swift test --filter ImportFixtureTests`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE_IMPORT_TESTS"] == "1"))
    func livePageStillExposesIngredients() async throws {
        let app = try await makeTestApp()

        do {
            let response = try await app.client.get(URI(string: Self.reportURL)).get()
            let html = response.body.map { String(decoding: $0.readableBytesView, as: UTF8.self) } ?? ""
            let structured = try #require(RecipeStructuredData.extract(from: html))
            #expect(structured.ingredients.count == 9)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
