import Fluent
import Foundation
import MealPlannerCore
import Testing
import Vapor
import XCTVapor
@testable import App

final class CapturingEmailSender: EmailSender, @unchecked Sendable {
    private let lock = NSLock()
    private var links: [(email: String, url: URL, client: String)] = []

    func sendMagicLink(to email: String, link: URL, client: String, logger: Logger) async throws {
        lock.withLock { links.append((email, link, client)) }
    }

    func lastLink() -> URL? {
        lock.withLock { links.last?.url }
    }
}

struct FakeAppleVerifier: AppleTokenVerifier {
    var subject = "apple-subject-1"
    var email = "apple@example.com"
    var shouldFail = false

    func verify(_ identityToken: String, nonce: String) async throws -> AppleIdentity {
        if shouldFail { throw AppError.appleTokenInvalid }
        return AppleIdentity(subject: subject, email: email)
    }
}

struct FakeFetcher: PageFetching {
    var html: String = "<html><title>Test Recipe</title><body>Recipe</body></html>"
    func fetch(_ url: URL) async throws -> FetchedPage {
        FetchedPage(url: url, html: html, title: "Test Recipe")
    }
}

struct FakeExtractor: RecipeExtracting {
    var draft: ImportedRecipeDraft?
    func extract(from page: FetchedPage) async throws -> ImportedRecipeDraft {
        if let draft { return draft }
        return ImportedRecipeDraft(
            title: "Imported Soup",
            servings: 2,
            ingredients: [ImportedIngredient(raw: "2 carrots", name: "Carrot", quantity: 2, unit: "piece")],
            instructions: ["Chop and simmer."],
            sourceURL: page.url
        )
    }
}

struct FakeImageStorage: ImageStoring {
    func store(sourceURL: URL, recipeID: UUID) async throws -> URL { sourceURL }
}

final class TestAppBox {
    let app: Application
    init(app: Application) { self.app = app }
    deinit { app.shutdown() }
}

@discardableResult
func makeTestApp(databaseValues: [String: String]? = nil) async throws -> Application {
    let env = Environment(name: "testing", arguments: ["App"])
    let app = try await Application.make(env)
    // Tests must not inherit a developer DATABASE_URL/DB_DRIVER; use the test DB.
    var values = ProcessInfo.processInfo.environment
    values.removeValue(forKey: "DATABASE_URL")
    values.removeValue(forKey: "DB_DRIVER")
    values.removeValue(forKey: "SQLITE_PATH")
    values["POSTGRES_DB"] = "mealplanner_test"
    try await configure(app, databaseValues: databaseValues ?? values)
    try await app.autoMigrate()
    app.emailSender = CapturingEmailSender()
    app.appleTokenVerifier = FakeAppleVerifier()
    return app
}

func resetDatabase(_ app: Application) async throws {
    let db = app.db
    try await deleteAll(AuditLogModel.self, on: db)
    try await deleteAll(ShoppingListDocumentModel.self, on: db)
    try await deleteAll(PlanDocumentModel.self, on: db)
    try await deleteAll(PlanMemberModel.self, on: db)
    try await deleteAll(MealPlanModel.self, on: db)
    try await deleteAll(ImportJobModel.self, on: db)
    try await deleteAll(RecipePersonalizationModel.self, on: db)
    try await deleteAll(RecipeBlockModel.self, on: db)
    try await deleteAll(RecipeFavoriteModel.self, on: db)
    try await deleteAll(RecipeShareModel.self, on: db)
    try await deleteAll(RecipeImageModel.self, on: db)
    try await deleteAll(RecipeIngredientModel.self, on: db)
    try await deleteAll(RecipeModel.self, on: db)
    try await deleteAll(FriendshipModel.self, on: db)
    try await deleteAll(FriendRequestModel.self, on: db)
    try await deleteAll(AdminSessionModel.self, on: db)
    try await deleteAll(RefreshTokenModel.self, on: db)
    try await deleteAll(MagicLinkTokenModel.self, on: db)
    try await deleteAll(UserDeviceModel.self, on: db)
    try await deleteAll(UserModel.self, on: db)
}

private func deleteAll<M: Model>(_ model: M.Type, on db: any Database) async throws {
    for item in try await M.query(on: db).all() {
        try await item.delete(force: true, on: db)
    }
}

func apiRequest<T: Decodable>(
    _ app: Application,
    _ method: HTTPMethod,
    _ path: String,
    headers: [String: String] = [:],
    body: (any Encodable)? = nil,
    expected: HTTPResponseStatus = .ok
) async throws -> T {
    var buffer: ByteBuffer?
    if let body {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(body)
        buffer = ByteBuffer(data: data)
    }

    var responseBody: ByteBuffer?
    try await app.test(
        method,
        path,
        headers: HTTPHeaders(headers.map { ($0.key, $0.value) }),
        body: buffer
    ) { (response: XCTHTTPResponse) async throws in
        #expect(response.status == expected, "Unexpected status for \(method) \(path): \(response.status) \(response.body.string)")
        responseBody = response.body
    }
    guard let responseBody else { throw TestError.noResponse }
    if responseBody.readableBytes == 0 {
        throw TestError.emptyResponse
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(T.self, from: responseBody)
    } catch {
        print("DECODE ERROR for \(path): \(error) body=\(responseBody.string)")
        throw error
    }
}

func apiResponse(
    _ app: Application,
    _ method: HTTPMethod,
    _ path: String,
    headers: [String: String] = [:],
    body: (any Encodable)? = nil,
    expected: HTTPResponseStatus = .ok
) async throws -> XCTHTTPResponse {
    var buffer: ByteBuffer?
    if let body {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        buffer = ByteBuffer(data: try encoder.encode(body))
    }
    var result: XCTHTTPResponse?
    try await app.test(
        method,
        path,
        headers: HTTPHeaders(headers.map { ($0.key, $0.value) }),
        body: buffer
    ) { (response: XCTHTTPResponse) async throws in
        #expect(response.status == expected, "Unexpected status for \(method) \(path): \(response.status)")
        result = response
    }
    guard let result else { throw TestError.noResponse }
    return result
}

func apiStatus(
    _ app: Application,
    _ method: HTTPMethod,
    _ path: String,
    headers: [String: String] = [:],
    body: (any Encodable)? = nil,
    expected: HTTPResponseStatus = .ok
) async throws {
    var buffer: ByteBuffer?
    if let body {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        buffer = ByteBuffer(data: try encoder.encode(body))
    }
    try await app.test(method, path, headers: HTTPHeaders(headers.map { ($0.key, $0.value) }), body: buffer) { (response: XCTHTTPResponse) async throws in
        #expect(response.status == expected, "Unexpected status for \(method) \(path): \(response.status) \(response.body.string)")
    }
}

enum TestError: Error {
    case noMagicLink
    case noResponse
    case emptyResponse
}

func signIn(_ app: Application, email: String = "user@example.com", deviceID: UUID = UUID()) async throws -> TokenPair {
    struct MagicBody: Encodable { var email: String }
    try await apiStatus(
        app, .POST, "/auth/magic-link",
        headers: ["Content-Type": "application/json", "X-Client": "ios"],
        body: MagicBody(email: email)
    )

    guard let sender = app.emailSender as? CapturingEmailSender, let link = sender.lastLink() else {
        throw TestError.noMagicLink
    }
    let components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
    let token = components.queryItems?.first { $0.name == "token" }?.value ?? ""

    struct VerifyBody: Encodable {
        var token: String
        var email: String
        var client: String
        var deviceID: UUID
        var deviceName: String = "iPhone"
    }

    return try await apiRequest(
        app, .POST, "/auth/verify",
        headers: ["Content-Type": "application/json"],
        body: VerifyBody(token: token, email: email, client: "ios", deviceID: deviceID)
    )
}

func makeAdmin(app: Application, email: String = "admin@example.com") async throws -> UserModel {
    let user = UserModel(email: email, displayName: "Admin", isAdmin: true)
    try await user.save(on: app.db)
    return user
}

func adminCookie(_ app: Application, email: String) async throws -> String {
    struct Body: Encodable { var email: String; var csrf: String = "none" }
    try await apiStatus(
        app, .POST, "/admin/login",
        headers: ["Content-Type": "application/json"],
        body: Body(email: email)
    )

    guard let link = (app.emailSender as? CapturingEmailSender)?.lastLink() else {
        throw TestError.noMagicLink
    }
    let components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
    let token = components.queryItems!.first { $0.name == "token" }!.value!

    var cookieValue: String?
    try await app.test(.GET, "/admin/verify?token=\(token)&email=\(email)") { (response: XCTHTTPResponse) async throws in
        #expect(response.status == .found)
        let setCookie = response.headers[.setCookie].first ?? ""
        cookieValue = setCookie.split(separator: ";").first.map(String.init)
    }
    guard let cookieValue else { throw TestError.noResponse }
    return cookieValue
}

func authHeaders(_ pair: TokenPair) -> [String: String] {
    ["Content-Type": "application/json", "Authorization": "Bearer \(pair.accessToken)"]
}

func createRecipe(_ app: Application, token: TokenPair, title: String = "Test Soup") async throws -> RecipeDTO {
    let body = RecipeCreateRequest(
        title: title,
        servings: 2,
        ingredients: [IngredientDTO(name: "Carrot", quantity: 2, unit: "piece", category: .produce)],
        instructions: ["Chop.", "Simmer."],
        dietaryTags: ["vegetarian"],
        visibility: .private
    )
    return try await apiRequest(app, .POST, "/recipes", headers: authHeaders(token), body: body)
}

func createPlan(_ app: Application, token: TokenPair, days: Int = 3) async throws -> PlanDTO {
    let body = PlanCreateRequest(
        name: "Test Week",
        startDate: CalendarDate(isoString: "2026-01-05")!,
        dayCount: days,
        slots: [.dinner],
        rules: PlanRules(),
        seed: 42
    )
    return try await apiRequest(app, .POST, "/plans", headers: authHeaders(token), body: body)
}


struct TestBody: @unchecked Sendable {
    let run: () async throws -> Void
}

actor GlobalTestGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ body: TestBody) async throws {
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isRunning = true
        }
        defer {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                isRunning = false
            }
        }
        try await body.run()
    }
}

let testGate = GlobalTestGate()
