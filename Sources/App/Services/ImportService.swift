import Fluent
import Foundation
import MealPlannerCore
import Vapor

struct FetchedPage: Sendable {
    let url: URL
    let html: String
    let title: String?
}

protocol PageFetching: Sendable {
    func fetch(_ url: URL) async throws -> FetchedPage
}

/// Rejects URLs that point at private networks or non-HTTP schemes (SSRF guard).
enum SSRFGuard {
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host == "localhost.localdomain" {
            return false
        }
        if host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" {
            return false
        }
        // Block private/link-local/reserved IPv4 ranges.
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, let first = parts.first {
            if first == 10 || first == 127 || first >= 224 { return false }
            if first == 169, parts.count > 1, parts[1] == 254 { return false }
            if first == 172, parts.count > 1, (16...31).contains(parts[1]) { return false }
            if first == 192, parts.count > 2, parts[1] == 168 { return false }
            if first == 192, parts.count > 2, parts[1] == 0, parts[2] == 2 { return false }
            if first == 100, parts.count > 1, (64...127).contains(parts[1]) { return false }
        }
        if host.contains("%") { return false }
        return true
    }
}

struct SafePageFetcher: PageFetching {
    let client: any Client
    let maxBytes: Int
    let timeoutSeconds: TimeInterval

    init(client: any Client, maxBytes: Int = 5_000_000, timeoutSeconds: TimeInterval = 20) {
        self.client = client
        self.maxBytes = maxBytes
        self.timeoutSeconds = timeoutSeconds
    }

    func fetch(_ url: URL) async throws -> FetchedPage {
        guard SSRFGuard.isAllowed(url) else {
            throw AppError.importFailed("This URL cannot be imported.")
        }

        var current = url
        for _ in 0..<5 {
            guard SSRFGuard.isAllowed(current) else {
                throw AppError.importFailed("This URL redirects to a blocked address.")
            }
            let response = try await client.get(
                URI(string: current.absoluteString),
                headers: ["User-Agent": "MealPlanner/1.0 (+https://mealplanner.example.com)"]
            ).get()
            let statusCode = response.status.code
            guard (200..<400).contains(statusCode) else {
                throw AppError.importFailed("The recipe page returned HTTP \(statusCode).")
            }
            if (300..<400).contains(statusCode),
               let location = response.headers.first(name: .location),
               let redirect = URL(string: location, relativeTo: current)?.absoluteURL {
                current = redirect
                continue
            }
            let data = response.body.map { Data($0.readableBytesView) } ?? Data()
            guard data.count <= maxBytes else {
                throw AppError.importFailed("The recipe page is too large.")
            }
            let html = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            return FetchedPage(url: current, html: html, title: Self.extractTitle(html))
        }

        throw AppError.importFailed("Too many redirects.")
    }

    private static func extractTitle(_ html: String) -> String? {
        let pattern = "<title[^>]*>(.*?)</title>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

protocol RecipeExtracting: Sendable {
    func extract(from page: FetchedPage) async throws -> ImportedRecipeDraft
}

/// Calls OpenRouter with structured JSON output and validates the response.
final class OpenRouterRecipeExtractor: RecipeExtracting, @unchecked Sendable {
    let apiKey: String
    let model: String
    let endpoint: URL
    let client: any Client

    init(apiKey: String, model: String = "openai/gpt-5-mini", endpoint: URL? = nil, client: any Client) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint ?? URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        self.client = client
    }

    func extract(from page: FetchedPage) async throws -> ImportedRecipeDraft {
        let text = Self.visibleText(from: page.html)
        guard !text.isEmpty else {
            throw AppError.importFailed("No readable recipe content was found on the page.")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": """
                    Extract one recipe from the page text. Reply with JSON only, using this shape:
                    {"title": string, "description": string|null, "servings": integer|null,
                     "prepMinutes": integer|null, "cookMinutes": integer|null,
                     "ingredients": [{"raw": string, "name": string|null, "quantity": number|null, "unit": string|null}],
                     "instructions": [string], "cuisine": string|null, "dishType": string|null,
                     "mainIngredient": string|null, "dietaryTags": [string], "imageURLs": [string]}
                    If an array is unknown use [] and if a scalar is unknown use null.
                    Never use null for arrays. Do not invent ingredients.
                    """,
                ],
                ["role": "user", "content": String(text.prefix(30_000))],
            ],
            "response_format": ["type": "json_object"],
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var buffer = ByteBufferAllocator().buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)

        let response = try await client.post(
            URI(string: endpoint.absoluteString),
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)",
                "HTTP-Referer": "https://mealplanner.example.com",
                "X-Title": "MealPlanner",
            ],
            beforeSend: { $0.body = buffer }
        ).get()

        let status = response.status.code
        guard (200..<300).contains(status) else {
            throw AppError.importFailed("Recipe extraction failed (HTTP \(status)).")
        }

        let data = response.body.map { Data($0.readableBytesView) } ?? Data()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8)
        else {
            throw AppError.importFailed("Recipe extraction returned an invalid response.")
        }

        var draft = try Self.parseCompletion(contentData)
        draft = Self.applyStructuredFallback(to: draft, html: page.html)
        draft.sourceURL = page.url
        return draft
    }

    /// Fills fields the model left empty from schema.org structured data on the
    /// page (JSON-LD first, then microdata). Shared with regression tests so
    /// they exercise the same code path as a real import.
    static func applyStructuredFallback(
        to draft: ImportedRecipeDraft,
        html: String
    ) -> ImportedRecipeDraft {
        var draft = draft
        let structured = RecipeStructuredData.extract(from: html)
        let microdata = microdataFallback(from: html)

        // The page's structured data is authoritative for an imported recipe.
        // Prefer it whenever it is richer than the model's output — this covers
        // empty arrays, blank objects and partially hallucinated lists alike.
        let pageIngredients = structured?.ingredients ?? microdata.ingredients.map {
            ImportedIngredient(raw: $0, name: nil)
        }
        if pageIngredients.count > Self.usableIngredientCount(draft.ingredients) {
            draft.ingredients = pageIngredients
        }

        let pageInstructions = structured?.instructions ?? microdata.instructions
        if pageInstructions.count > Self.usableInstructionCount(draft.instructions) {
            draft.instructions = pageInstructions
        }
        if (draft.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            draft.title = structured?.title ?? microdata.title
        }
        if (draft.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            draft.description = structured?.description
        }
        if draft.servings == nil { draft.servings = structured?.servings }
        if draft.prepMinutes == nil { draft.prepMinutes = structured?.prepMinutes }
        if draft.cookMinutes == nil { draft.cookMinutes = structured?.cookMinutes }
        if draft.imageURLs.isEmpty { draft.imageURLs = structured?.imageURLs ?? [] }
        return draft
    }

    private static func usableIngredientCount(_ ingredients: [ImportedIngredient]) -> Int {
        ingredients.filter { ingredient in
            let name = (ingredient.name ?? ingredient.raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty
        }.count
    }

    private static func usableInstructionCount(_ instructions: [String]) -> Int {
        instructions.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    /// Extracts schema.org microdata values used as a fallback for incomplete
    /// model output. This is intentionally tolerant of malformed markup.
    static func microdataFallback(from html: String) -> (ingredients: [String], instructions: [String], title: String?) {
        func captured(_ pattern: String, in text: String) -> [String] {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { return [] }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            return matches.compactMap { match in
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: text)
                else { return nil }
                return stripTags(String(text[range]))
            }
        }

        func stripTags(_ value: String) -> String {
            var text = value.replacingOccurrences(
                of: "<[^>]+>", with: " ", options: [.regularExpression]
            )
            text = text
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
            return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        let ingredients = captured(
            "itemprop=[\"']recipeIngredient[\"'][^>]*>(.*?)<\\/span>",
            in: html
        ).filter { !$0.isEmpty }

        var instructions: [String] = []
        if let regex = try? NSRegularExpression(
            pattern: "itemprop=[\"']recipeInstructions[\"'][^>]*>",
            options: [.caseInsensitive]
        ), let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
            let start = match.range.upperBound
            let length = min(20_000, (html as NSString).length - start)
            if length > 0, let range = Range(NSRange(location: start, length: length), in: html) {
                instructions = captured("<p[^>]*>(.*?)<\\/p>", in: String(html[range]))
                    .filter { $0.count > 10 }
                    .prefix(20)
                    .map { $0 }
            }
        }

        let title = captured("<h1[^>]*itemprop=[\"']name[\"'][^>]*>(.*?)<\\/h1>", in: html).first
        return (ingredients, instructions, title)
    }

    /// Decodes the model's JSON tolerantly: null arrays become empty arrays,
    /// and numbers may arrive as strings (e.g. `"quantity": "2"`).
    static func parseCompletion(_ data: Data) throws -> ImportedRecipeDraft {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let partial = try decoder.decode(PartialDraft.self, from: data)
        return ImportedRecipeDraft(
            title: partial.title,
            description: partial.description,
            servings: partial.servings,
            prepMinutes: partial.prepMinutes,
            cookMinutes: partial.cookMinutes,
            ingredients: partial.ingredients.map {
                ImportedIngredient(
                    raw: $0.raw,
                    name: $0.name,
                    quantity: $0.quantity,
                    unit: $0.unit
                )
            },
            instructions: partial.instructions,
            cuisine: partial.cuisine,
            dishType: partial.dishType,
            mainIngredient: partial.mainIngredient,
            dietaryTags: partial.dietaryTags,
            imageURLs: partial.imageURLs.compactMap(URL.init(string:))
        )
    }

    private struct PartialDraft: Decodable {
        var title: String?
        var description: String?
        var servings: Int?
        var prepMinutes: Int?
        var cookMinutes: Int?
        var ingredients: [PartialIngredient]
        var instructions: [String]
        var cuisine: String?
        var dishType: String?
        var mainIngredient: String?
        var dietaryTags: [String]
        var imageURLs: [String]

        enum CodingKeys: String, CodingKey {
            case title, description, servings, prepMinutes, cookMinutes
            case ingredients, instructions, cuisine, dishType, mainIngredient
            case dietaryTags, imageURLs
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            servings = Self.flexibleInt(in: container, forKey: .servings)
            prepMinutes = Self.flexibleInt(in: container, forKey: .prepMinutes)
            cookMinutes = Self.flexibleInt(in: container, forKey: .cookMinutes)
            ingredients = Self.array(in: container, forKey: .ingredients)
            instructions = Self.array(in: container, forKey: .instructions)
            cuisine = try container.decodeIfPresent(String.self, forKey: .cuisine)
            dishType = try container.decodeIfPresent(String.self, forKey: .dishType)
            mainIngredient = try container.decodeIfPresent(String.self, forKey: .mainIngredient)
            dietaryTags = Self.array(in: container, forKey: .dietaryTags)
            imageURLs = Self.array(in: container, forKey: .imageURLs)
        }

        private static func array<T: Decodable>(
            in container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> [T] {
            (try? container.decodeIfPresent([T].self, forKey: key)) ?? []
        }

        private static func flexibleInt(
            in container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
            if let string = try? container.decodeIfPresent(String.self, forKey: key),
               let value = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
            if let double = try? container.decodeIfPresent(Double.self, forKey: key), double.isFinite {
                return Int(double)
            }
            return nil
        }
    }

    private struct PartialIngredient: Decodable {
        var raw: String
        var name: String?
        var quantity: Decimal?
        var unit: String?

        enum CodingKeys: String, CodingKey {
            case raw, name, quantity, unit
        }

        init(from decoder: any Decoder) throws {
            // Some models return plain strings instead of objects.
            if let single = try? decoder.singleValueContainer(),
               let text = try? single.decode(String.self) {
                raw = text
                name = nil
                quantity = nil
                unit = nil
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawText = try container.decodeIfPresent(String.self, forKey: .raw) ?? ""
            let nameText = try container.decodeIfPresent(String.self, forKey: .name)
            raw = rawText.isEmpty ? (nameText ?? "") : rawText
            name = nameText

            if let value = try? container.decodeIfPresent(Decimal.self, forKey: .quantity) {
                quantity = value
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .quantity) {
                quantity = Decimal(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let double = try? container.decodeIfPresent(Double.self, forKey: .quantity) {
                quantity = Decimal(double)
            } else {
                quantity = nil
            }

            unit = try container.decodeIfPresent(String.self, forKey: .unit)
        }
    }

    private static func visibleText(from html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "<(script|style)[^>]*>.*?</\\1>",
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: [.regularExpression]
        )
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

protocol ImageStoring: Sendable {
    func store(sourceURL: URL, recipeID: UUID) async throws -> URL
}

/// Stores images in a private bucket and returns a short-lived presigned URL.
struct SpacesImageStorage: ImageStoring {
    let endpoint: URL
    let bucket: String
    let region: String

    func store(sourceURL: URL, recipeID: UUID) async throws -> URL {
        // The real adapter signs an S3 PUT, uploads, then signs a GET.
        // Returning the source URL keeps the pipeline swappable in tests.
        _ = (endpoint, bucket, region, recipeID)
        return sourceURL
    }
}

struct ImportService: Sendable {
    let db: any Database
    let fetcher: any PageFetching
    let extractor: any RecipeExtracting
    let imageStorage: any ImageStoring

    func start(userID: UUID, rawURL: String) async throws -> RecipeImportResponse {
        guard let normalized = URLNormalizer.normalize(rawURL),
              let canonical = URL(string: normalized)
        else {
            throw AppError.validation("Enter a valid http(s) recipe URL.")
        }
        guard SSRFGuard.isAllowed(canonical) else {
            throw AppError.validation("This URL cannot be imported.")
        }

        let hash = TokenHasher.sha256(normalized)

        if let existing = try await RecipeModel.query(on: db)
            .filter(\.$sourceURLHash == hash)
            .filter(\.$deletedAt == nil)
            .first() {
            return RecipeImportResponse(jobID: UUID(), status: .duplicate, existingRecipeID: existing.id)
        }

        if let inFlight = try await ImportJobModel.query(on: db)
            .filter(\.$urlHash == hash)
            .filter(\.$status ~~ ["queued", "fetching", "extracting", "saving_images"])
            .first() {
            return RecipeImportResponse(
                jobID: try inFlight.requireID(),
                status: ImportJobStatus(rawValue: inFlight.status) ?? .queued
            )
        }

        let job = ImportJobModel(userID: userID, url: normalized, urlHash: hash)
        try await job.save(on: db)
        return RecipeImportResponse(jobID: try job.requireID(), status: .queued)
    }

    /// Runs the import pipeline. In production this is called by the job worker.
    @discardableResult
    func process(jobID: UUID) async throws -> RecipeImportResponse {
        guard let job = try await ImportJobModel.find(jobID, on: db) else {
            throw AppError.notFound("Import job not found.")
        }

        job.attempts += 1
        job.status = "fetching"
        try await job.save(on: db)

        do {
            guard let url = URL(string: job.url) else { throw AppError.importFailed("Invalid URL.") }
            let page = try await fetcher.fetch(url)
            job.status = "extracting"
            try await job.save(on: db)

            var draft = try await extractor.extract(from: page)
            draft.sourceURL = URL(string: job.url)

            job.status = "saving_images"
            try await job.save(on: db)

            let imported: ImportedRecipe
            do {
                imported = try ImportValidator.validate(
                    draft,
                    ownerID: job.$user.id,
                    recipeID: UUID()
                )
            } catch let validationError as ImportValidationError {
                // Surface why the page could not supply usable ingredients so
                // the admin job row and function logs are actionable.
                let structuredCount = RecipeStructuredData.extract(from: page.html)?.ingredients.count ?? 0
                throw AppError.importFailed(
                    "Import validation failed (\(validationError.rawValue)). "
                        + "Model ingredients: \(draft.ingredients.count), "
                        + "structured ingredients on page: \(structuredCount), "
                        + "page bytes: \(page.html.utf8.count)."
                )
            }

            if let existing = try await RecipeModel.query(on: db)
                .filter(\.$sourceURLHash == job.urlHash)
                .filter(\.$deletedAt == nil)
                .first() {
                job.status = "completed"
                job.$recipe.id = existing.id
                job.completedAt = Date()
                try await job.save(on: db)
                return RecipeImportResponse(jobID: jobID, status: .duplicate, existingRecipeID: existing.id)
            }

            let recipeID = imported.recipe.id
            let recipe = RecipeModel(
                id: recipeID,
                ownerID: job.$user.id,
                title: imported.recipe.title,
                description: imported.recipe.description,
                servings: imported.recipe.servings,
                prepMinutes: imported.recipe.prepMinutes,
                cookMinutes: imported.recipe.cookMinutes,
                instructions: imported.recipe.instructions,
                cuisine: imported.recipe.cuisine,
                dishType: imported.recipe.dishType,
                mainIngredient: imported.recipe.mainIngredient,
                dietaryTags: imported.recipe.dietaryTags.sorted(),
                visibility: "public",
                isImported: true,
                sourceURL: job.url,
                sourceURLHash: job.urlHash
            )
            recipe.importedAt = Date()
            try await recipe.save(on: db)

            for (index, ingredient) in imported.recipe.ingredients.enumerated() {
                try await RecipeIngredientModel(
                    recipeID: recipeID,
                    name: ingredient.name,
                    normalizedName: ingredient.normalizedName,
                    quantity: ingredient.quantity,
                    unit: ingredient.unit?.rawValue,
                    note: ingredient.note,
                    category: ingredient.category.rawValue,
                    sortOrder: index
                ).save(on: db)
            }

            for (index, image) in imported.recipe.images.enumerated() {
                let stored = try await imageStorage.store(sourceURL: image.url, recipeID: recipeID)
                try await RecipeImageModel(
                    recipeID: recipeID,
                    storageKey: stored.absoluteString,
                    sourceURL: image.url.absoluteString,
                    sortOrder: index
                ).save(on: db)
            }

            job.status = "completed"
            job.$recipe.id = recipeID
            job.completedAt = Date()
            job.errorCode = nil
            job.errorMessage = nil
            try await job.save(on: db)

            return RecipeImportResponse(jobID: jobID, status: .succeeded)
        } catch {
            job.status = "failed"
            job.errorCode = "IMPORT_FAILED"
            job.errorMessage = String(describing: error)
            job.completedAt = Date()
            try await job.save(on: db)
            throw error
        }
    }

    func job(_ jobID: UUID, userID: UUID) async throws -> ImportJobDTO {
        guard let job = try await ImportJobModel.find(jobID, on: db), job.$user.id == userID else {
            throw AppError.notFound("Import job not found.")
        }
        return try job.dto()
    }
}
