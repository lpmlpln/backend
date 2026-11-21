import Foundation
import MealPlannerCore
import Testing
import XCTVapor
import Vapor
@testable import App

@Suite(.serialized)
struct HealthAndAuthTests {
    @Test("Health endpoint responds")
    func health() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await apiStatus(app, .GET, "/health")
        try await app.asyncShutdown()
    
        })}

    @Test("Magic link flow authenticates and returns tokens")
    func magicLink() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)

        let pair = try await signIn(app)
        #expect(!pair.accessToken.isEmpty)
        #expect(!pair.refreshToken.isEmpty)
        #expect(pair.user.email == "user@example.com")
        try await app.asyncShutdown()
    
        })}

    @Test("Magic links are single use")
    func singleUse() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)

        struct MagicBody: Encodable { var email = "single@example.com" }
        try await apiStatus(
            app, .POST, "/auth/magic-link",
            headers: ["Content-Type": "application/json", "X-Client": "ios"],
            body: MagicBody()
        )
        let link = (app.emailSender as! CapturingEmailSender).lastLink()!
        let token = URLComponents(url: link, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "token" }!.value!

        struct VerifyBody: Encodable {
            var token: String
            var email = "single@example.com"
            var client = "ios"
            var deviceID = UUID()
            var deviceName = "iPhone"
        }
        try await apiStatus(app, .POST, "/auth/verify", headers: ["Content-Type": "application/json"], body: VerifyBody(token: token))
        let response = try await app.test(.POST, "/auth/verify", headers: ["Content-Type": "application/json"], body: ByteBuffer(data: JSONEncoder().encode(VerifyBody(token: token)))) { (response: XCTHTTPResponse) async throws in
            #expect(response.status == .unauthorized)
        }
        _ = response
        try await app.asyncShutdown()
    
        })}

    @Test("Refresh rotates the token")
    func refresh() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)

        let pair = try await signIn(app)
        struct RefreshBody: Encodable { var refreshToken: String }
        let rotated: TokenPair = try await apiRequest(
            app, .POST, "/auth/refresh",
            headers: ["Content-Type": "application/json"],
            body: RefreshBody(refreshToken: pair.refreshToken)
        )
        #expect(rotated.refreshToken != pair.refreshToken)

        let body = ByteBuffer(data: try JSONEncoder().encode(RefreshBody(refreshToken: pair.refreshToken)))
        try await app.test(
            .POST, "/auth/refresh",
            headers: ["Content-Type": "application/json"],
            body: body
        ) { (response: XCTHTTPResponse) async throws in
            #expect(response.status == .unauthorized)
        }
        try await app.asyncShutdown()
    
        })}

    @Test("Apple sign in works with a fake verifier")
    func appleSignIn() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)

        struct Body: Encodable {
            var identityToken = "fake-token"
            var nonce = "nonce"
            var displayName = "Apple User"
        }
        let pair: TokenPair = try await apiRequest(
            app, .POST, "/auth/apple",
            headers: ["Content-Type": "application/json"],
            body: Body()
        )
        #expect(pair.user.email == "apple@example.com")
        try await app.asyncShutdown()
    
        })}

    @Test("Protected routes require authentication")
    func unauthorized() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        try await apiStatus(app, .GET, "/me", expected: .unauthorized)
        try await app.asyncShutdown()
    
        })}

    @Test("Account deletion anonymizes the user")
    func deleteAccount() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)

        let pair = try await signIn(app)
        try await apiStatus(app, .DELETE, "/me", headers: authHeaders(pair), expected: .noContent)
        try await apiStatus(app, .GET, "/me", headers: authHeaders(pair), expected: .unauthorized)
        try await app.asyncShutdown()
    
        })}
}
