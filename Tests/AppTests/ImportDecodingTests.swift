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

    @Test("schema.org JSON-LD supplies ingredients and instructions")
    func jsonLDFallback() throws {
        let html = """
        <html><head>
        <script type="application/ld+json">
        {"@context":"https://schema.org","@graph":[
          {"@type":"WebPage","name":"Recipe page"},
          {"@type":"Recipe",
           "name":"Spring Cutlets with Arugula and Tomatoes",
           "description":"A spring recipe.",
           "recipeYield":["4","4 servings"],
           "prepTime":"PT15M","cookTime":"PT10M",
           "recipeIngredient":[
             "4 nr cutlets ( of veal)","50 gr butter","2 nr eggs",
             "to taste breadcrumbs","3 nr fresh tomatoes","1 bunch arugula",
             "to taste extra virgin olive oil","to taste wine vinegar","1 pinch salt"
           ],
           "recipeInstructions":[
             {"@type":"HowToStep","text":"Beat the eggs in a bowl."},
             {"@type":"HowToStep","text":"Dip the cutlets in the eggs."}
           ],
           "image":["https://example.com/cutlets.jpg"]
          }
        ]}
        </script></head></html>
        """

        let structured = try #require(RecipeStructuredData.extract(from: html))
        #expect(structured.title == "Spring Cutlets with Arugula and Tomatoes")
        #expect(structured.servings == 4)
        #expect(structured.prepMinutes == 15)
        #expect(structured.cookMinutes == 10)
        #expect(structured.ingredients.count == 9)
        #expect(structured.instructions.count == 2)
        #expect(structured.imageURLs.map(\.absoluteString) == ["https://example.com/cutlets.jpg"])

        var draft = try OpenRouterRecipeExtractor.parseCompletion(Data(
            """
            {"title":null,"ingredients":null,"instructions":null,
             "servings":null,"imageURLs":null,"dietaryTags":null}
            """.utf8
        ))
        draft.ingredients = structured.ingredients
        draft.instructions = structured.instructions
        draft.title = structured.title
        draft.description = structured.description
        draft.servings = structured.servings
        draft.prepMinutes = structured.prepMinutes
        draft.cookMinutes = structured.cookMinutes
        draft.imageURLs = structured.imageURLs
        draft.sourceURL = URL(string: "https://verdegusto.it/en/ricette/spring-cutlets-with-arugula-and-tomatoes-spring-recipe")

        let imported = try ImportValidator.validate(draft, ownerID: UUID())
        #expect(imported.recipe.ingredients.count == 9)
        #expect(imported.recipe.instructions.count == 2)
        #expect(imported.recipe.servings == 4)
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
