import Foundation
import MealPlannerCore

/// A recipe extracted from schema.org JSON-LD markup. Used as a fallback when
/// the model omits fields that are present in the page's structured data.
struct StructuredRecipeDraft {
    var title: String?
    var description: String?
    var servings: Int?
    var prepMinutes: Int?
    var cookMinutes: Int?
    var ingredients: [ImportedIngredient]
    var instructions: [String]
    var imageURLs: [URL]
}

enum RecipeStructuredData {
    static func extract(from html: String) -> StructuredRecipeDraft? {
        guard let regex = try? NSRegularExpression(
            pattern: "<script[^>]*type=[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }

        let text = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: text.length))

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let body = text.substring(with: match.range(at: 1))
            guard let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let recipe = findRecipe(in: json, depth: 0)
            else { continue }
            return convert(recipe)
        }
        return nil
    }

    private static func findRecipe(in value: Any?, depth: Int) -> [String: Any]? {
        guard depth < 6 else { return nil }

        if let dictionary = value as? [String: Any] {
            if isRecipe(dictionary) { return dictionary }
            if let graph = dictionary["@graph"] as? [Any] {
                for node in graph {
                    if let found = findRecipe(in: node, depth: depth + 1) { return found }
                }
            }
            for nested in dictionary.values {
                if let found = findRecipe(in: nested, depth: depth + 1) { return found }
            }
        } else if let array = value as? [Any] {
            for item in array {
                if let found = findRecipe(in: item, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private static func isRecipe(_ dictionary: [String: Any]) -> Bool {
        if let type = dictionary["@type"] as? String {
            return type.caseInsensitiveCompare("Recipe") == .orderedSame
        }
        if let types = dictionary["@type"] as? [Any] {
            return types.contains { value in
                guard let string = value as? String else { return false }
                return string.caseInsensitiveCompare("Recipe") == .orderedSame
            }
        }
        return false
    }

    private static func convert(_ recipe: [String: Any]) -> StructuredRecipeDraft {
        let ingredients = strings(recipe["recipeIngredient"]).map {
            ImportedIngredient(raw: $0, name: nil)
        }
        let instructions = strings(recipe["recipeInstructions"])
        let images = imageStrings(recipe["image"]).compactMap(URL.init(string:))

        return StructuredRecipeDraft(
            title: firstString(recipe["name"]),
            description: firstString(recipe["description"]),
            servings: firstInt(recipe["recipeYield"]),
            prepMinutes: durationMinutes(recipe["prepTime"]),
            cookMinutes: durationMinutes(recipe["cookTime"]),
            ingredients: ingredients,
            instructions: instructions,
            imageURLs: images
        )
    }

    private static func strings(_ value: Any?) -> [String] {
        guard let value else { return [] }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let number = value as? NSNumber {
            return [number.stringValue]
        }
        if let array = value as? [Any] {
            return array.flatMap { strings($0) }
        }
        if let dictionary = value as? [String: Any] {
            for key in ["text", "name", "url", "value"] {
                if let found = firstString(dictionary[key]) { return [found] }
            }
            if let steps = dictionary["itemListElement"] {
                return strings(steps)
            }
        }
        return []
    }

    private static func imageStrings(_ value: Any?) -> [String] {
        guard let value else { return [] }
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap { imageStrings($0) } }
        if let dictionary = value as? [String: Any] {
            return imageStrings(dictionary["url"])
        }
        return []
    }

    private static func firstString(_ value: Any?) -> String? {
        strings(value).first
    }

    private static func firstInt(_ value: Any?) -> Int? {
        guard let text = firstString(value) else { return nil }
        let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .joined()
        return Int(digits).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func durationMinutes(_ value: Any?) -> Int? {
        guard let text = firstString(value) else { return nil }
        let pattern = "^PT(?:(\\d+)H)?(?:(\\d+)M)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func group(_ index: Int) -> Int {
            guard match.numberOfRanges > index,
                  let range = Range(match.range(at: index), in: text),
                  let value = Int(text[range])
            else { return 0 }
            return value
        }

        let minutes = group(1) * 60 + group(2)
        return minutes > 0 ? minutes : nil
    }
}
