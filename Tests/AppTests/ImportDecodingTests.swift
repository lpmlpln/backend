import Foundation
import MealPlannerCore
import Testing
@testable import App

@Suite("OpenRouter response decoding")
struct OpenRouterDecodingTests {
    @Test("Null arrays and stringified numbers are tolerated")
    func nullArraysAndStrings() throws {
        let json = """
        {
          "title": "Domowe tortille pszenne",
          "servings": "4",
          "prepMinutes": "15",
          "cookMinutes": null,
          "ingredients": null,
          "instructions": null,
          "dietaryTags": null,
          "imageURLs": null,
          "description": null,
          "cuisine": null,
          "dishType": null,
          "mainIngredient": null
        }
        """
        let draft = try OpenRouterRecipeExtractor.parseCompletion(Data(json.utf8))
        #expect(draft.title == "Domowe tortille pszenne")
        #expect(draft.servings == 4)
        #expect(draft.prepMinutes == 15)
        #expect(draft.cookMinutes == nil)
        #expect(draft.ingredients.isEmpty)
        #expect(draft.instructions.isEmpty)
        #expect(draft.dietaryTags.isEmpty)
        #expect(draft.imageURLs.isEmpty)
    }

    @Test("Plain-string ingredients and string quantities are accepted")
    func flexibleIngredients() throws {
        let json = """
        {
          "title": "Soup",
          "ingredients": ["2 cups flour", "salt"],
          "instructions": ["Mix", "Cook"],
          "dietaryTags": ["vegan"]
        }
        """
        let draft = try OpenRouterRecipeExtractor.parseCompletion(Data(json.utf8))
        #expect(draft.ingredients.count == 2)
        #expect(draft.ingredients[0].raw == "2 cups flour")
        #expect(draft.ingredients[1].raw == "salt")
        #expect(draft.instructions.count == 2)
    }

    @Test("Object ingredients with numeric strings decode quantity")
    func stringQuantity() throws {
        let json = """
        {
          "title": "Soup",
          "ingredients": [
            {"raw": "2.5 cups flour", "name": "flour", "quantity": "2.5", "unit": "cup"}
          ]
        }
        """
        let draft = try OpenRouterRecipeExtractor.parseCompletion(Data(json.utf8))
        #expect(draft.ingredients.count == 1)
        #expect(draft.ingredients[0].quantity == Decimal(string: "2.5"))
        #expect(draft.ingredients[0].name == "flour")
        #expect(draft.ingredients[0].unit == "cup")
    }

    @Test("Null arrays are filled from microdata before validation")
    func microdataFallback() throws {
        let json = """
        {
          "title": null,
          "servings": 8,
          "ingredients": null,
          "instructions": null,
          "imageURLs": null,
          "dietaryTags": null
        }
        """
        var draft = try OpenRouterRecipeExtractor.parseCompletion(Data(json.utf8))
        let html = """
        <h1 itemprop="name">Domowe tortille pszenne</h1>
        <div itemprop="recipeInstructions"><p>Mieszaj ciasto przez dziesięć minut i odstaw na pół godziny.</p></div>
        <ul>
          <li><span itemprop="recipeIngredient"><span>400 g mąki pszennej</span></span></li>
          <li><span itemprop="recipeIngredient"><span>200 ml wrzątku</span></span></li>
        </ul>
        """
        let fallback = OpenRouterRecipeExtractor.microdataFallback(from: html)
        #expect(fallback.title == "Domowe tortille pszenne")
        #expect(fallback.ingredients.count == 2)
        #expect(fallback.instructions.count == 1)

        if draft.ingredients.isEmpty {
            draft.ingredients = fallback.ingredients.map { ImportedIngredient(raw: $0, name: nil) }
        }
        if draft.instructions.isEmpty { draft.instructions = fallback.instructions }
        if (draft.title ?? "").isEmpty { draft.title = fallback.title }
        draft.sourceURL = URL(string: "https://aniagotuje.pl/przepis/domowe-tortille-pszenne")

        let imported = try ImportValidator.validate(draft, ownerID: UUID())
        #expect(imported.recipe.title == "Domowe tortille pszenne")
        #expect(imported.recipe.ingredients.count == 2)
        #expect(imported.recipe.instructions.count == 1)
        #expect(imported.recipe.visibility == .public)
    }
}
