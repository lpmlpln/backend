import Foundation
import MealPlannerCore
import Testing
import XCTVapor
import Vapor
@testable import App

@Suite(.serialized)
struct AdminTests {
    func makeAdmin(app: Application, email: String = "admin@example.com") async throws -> (UserModel, String) {
        let user = UserModel(email: email, displayName: "Admin", isAdmin: true)
        try await user.save(on: app.db)
        return (user, email)
        try await app.asyncShutdown()
    }

    func adminCookie(_ app: Application, email: String) async throws -> String {
        struct Body: Encodable { var email: String; var csrf: String = "none" }
        try await apiStatus(
            app, .POST, "/admin/login",
            headers: ["Content-Type": "application/json"],
            body: Body(email: email)
        )
        let link = (app.emailSender as! CapturingEmailSender).lastLink()!
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
        try await app.asyncShutdown()
    }

    @Test("Non-admin cannot access the dashboard")
    func nonAdminDenied() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        try await apiStatus(app, .GET, "/admin", expected: .unauthorized)
        try await app.asyncShutdown()
    
        })}

    @Test("Admin can access the dashboard and manage users")
    func adminFlow() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        _ = try await makeAdmin(app: app)
        let cookie = try await adminCookie(app, email: "admin@example.com")

        try await apiStatus(app, .GET, "/admin", headers: ["Cookie": cookie])
        try await apiStatus(app, .GET, "/admin/users", headers: ["Cookie": cookie])
        try await apiStatus(app, .GET, "/admin/imports", headers: ["Cookie": cookie])
        try await apiStatus(app, .GET, "/admin/audit", headers: ["Cookie": cookie])
        try await app.asyncShutdown()
    
        })}

    @Test("CSRF is enforced")
    func csrf() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let (user, _) = try await makeAdmin(app: app)
        let cookie = try await adminCookie(app, email: "admin@example.com")

        // Missing CSRF token is rejected.
        struct Body: Encodable { var csrf: String = "wrong" }
        try await apiStatus(
            app, .POST, "/admin/users/\(user.requireID().uuidString)/disable",
            headers: ["Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"],
            body: Body(), expected: .forbidden
        )
        try await app.asyncShutdown()
    
        })}

    @Test("Non-admin cannot use an admin magic link")
    func nonAdminMagicLink() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let plain = UserModel(email: "plain@example.com", displayName: "Plain")
        try await plain.save(on: app.db)

        struct Body: Encodable { var email: String; var csrf: String = "none" }
        try await apiStatus(
            app, .POST, "/admin/login",
            headers: ["Content-Type": "application/json"],
            body: Body(email: "plain@example.com")
        )
        let link = (app.emailSender as! CapturingEmailSender).lastLink()!
        let components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        let token = components.queryItems!.first { $0.name == "token" }!.value!
        try await apiStatus(app, .GET, "/admin/verify?token=\(token)&email=plain@example.com", expected: .forbidden)
        try await app.asyncShutdown()
    
        })}
}
