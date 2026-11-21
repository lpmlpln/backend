import Foundation
import MealPlannerCore
import Testing
import XCTVapor
import Vapor
@testable import App

@Suite(.serialized)
struct SyncTests {
    @Test("Pull returns plan state for a member")
    func pull() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        _ = try await createRecipe(app, token: user)
        let plan = try await createPlan(app, token: user)

        let response: SyncPullResponse = try await apiRequest(app, .GET, "/sync/pull", headers: authHeaders(user))
        #expect(response.plans.contains { $0.planID == plan.id })
        #expect(response.shoppingLists.contains { $0.planID == plan.id })
        #expect(!response.cursor.value.isEmpty)
        try await app.asyncShutdown()
    
        })}

    @Test("Push merges a CRDT document and is idempotent")
    func push() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        _ = try await createRecipe(app, token: user)
        let plan = try await createPlan(app, token: user, days: 2)

        let pull: SyncPullResponse = try await apiRequest(app, .GET, "/sync/pull", headers: authHeaders(user))
        let payload = pull.plans.first { $0.planID == plan.id }!

        var state = payload.state
        let key = state.materializedEntries()[0].key
        state.setLocked(true, entryKey: key, clock: HLC(wallTimeMillis: Int64(Date().timeIntervalSince1970 * 1000) + 10_000, counter: 0, nodeID: UUID()))

        struct Body: Encodable {
            var deviceID: UUID
            var plans: [SyncPlanPayload]
            var shoppingLists: [SyncShoppingPayload] = []
        }
        let body = Body(deviceID: user.user.id, plans: [SyncPlanPayload(planID: plan.id, state: state)])

        let first: SyncPushResponse = try await apiRequest(app, .POST, "/sync/push", headers: authHeaders(user), body: body)
        #expect(first.plans.count == 1)
        #expect(first.rejections.isEmpty)
        #expect(first.plans[0].state.entries[key.rawValue]?.locked.value == true)

        let second: SyncPushResponse = try await apiRequest(app, .POST, "/sync/push", headers: authHeaders(user), body: body)
        #expect(second.rejections.isEmpty)
        #expect(second.plans[0].state.entries[key.rawValue]?.locked.value == true)
        try await app.asyncShutdown()
    
        })}

    @Test("Editor cannot change owner-only fields")
    func protectedFields() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let owner = try await signIn(app, email: "owner@example.com")
        let editor = try await signIn(app, email: "editor@example.com")
        _ = try await createRecipe(app, token: owner)
        let plan = try await createPlan(app, token: owner)

        struct FriendBody: Encodable { var email: String }
        try await apiStatus(app, .POST, "/friends", headers: authHeaders(editor), body: FriendBody(email: "owner@example.com"), expected: .accepted)
        try await apiStatus(app, .POST, "/friends/\(editor.user.id.uuidString)/accept", headers: authHeaders(owner))
        struct MemberBody: Encodable { var userID: UUID; var role = PlanRole.editor }
        try await apiStatus(app, .POST, "/plans/\(plan.id.uuidString)/members", headers: authHeaders(owner), body: MemberBody(userID: editor.user.id))

        let pull: SyncPullResponse = try await apiRequest(app, .GET, "/sync/pull", headers: authHeaders(editor))
        var state = pull.plans.first { $0.planID == plan.id }!.state
        let future = HLC(
            wallTimeMillis: Int64(Date().timeIntervalSince1970 * 1000) + 100_000,
            counter: 0,
            nodeID: UUID()
        )
        state.metadata.name = state.metadata.name.updated(to: "Hacked", at: future)

        struct Body: Encodable { var deviceID: UUID; var plans: [SyncPlanPayload] }
        let response: SyncPushResponse = try await apiRequest(
            app, .POST, "/sync/push", headers: authHeaders(editor),
            body: Body(deviceID: editor.user.id, plans: [SyncPlanPayload(planID: plan.id, state: state)])
        )
        #expect(response.rejections.count == 1)
        #expect(response.rejections[0].code == .planRoleInsufficient)
        try await app.asyncShutdown()
    
        })}

    @Test("Viewer cannot push")
    func viewerPush() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let owner = try await signIn(app, email: "owner@example.com")
        let viewer = try await signIn(app, email: "viewer@example.com")
        _ = try await createRecipe(app, token: owner)
        let plan = try await createPlan(app, token: owner)

        struct FriendBody: Encodable { var email: String }
        try await apiStatus(app, .POST, "/friends", headers: authHeaders(viewer), body: FriendBody(email: "owner@example.com"), expected: .accepted)
        try await apiStatus(app, .POST, "/friends/\(viewer.user.id.uuidString)/accept", headers: authHeaders(owner))
        struct MemberBody: Encodable { var userID: UUID; var role = PlanRole.viewer }
        try await apiStatus(app, .POST, "/plans/\(plan.id.uuidString)/members", headers: authHeaders(owner), body: MemberBody(userID: viewer.user.id))

        let pull: SyncPullResponse = try await apiRequest(app, .GET, "/sync/pull", headers: authHeaders(viewer))
        let state = pull.plans.first { $0.planID == plan.id }!.state
        struct Body: Encodable { var deviceID: UUID; var plans: [SyncPlanPayload] }
        let response: SyncPushResponse = try await apiRequest(
            app, .POST, "/sync/push", headers: authHeaders(viewer),
            body: Body(deviceID: viewer.user.id, plans: [SyncPlanPayload(planID: plan.id, state: state)])
        )
        #expect(response.rejections.first?.code == .planRoleInsufficient)
        try await app.asyncShutdown()
    
        })}

    @Test("Revoked member receives a revocation on pull")
    func revokedPull() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let owner = try await signIn(app, email: "owner@example.com")
        let editor = try await signIn(app, email: "editor@example.com")
        _ = try await createRecipe(app, token: owner)
        let plan = try await createPlan(app, token: owner)

        struct FriendBody: Encodable { var email: String }
        try await apiStatus(app, .POST, "/friends", headers: authHeaders(editor), body: FriendBody(email: "owner@example.com"), expected: .accepted)
        try await apiStatus(app, .POST, "/friends/\(editor.user.id.uuidString)/accept", headers: authHeaders(owner))
        struct MemberBody: Encodable { var userID: UUID; var role = PlanRole.editor }
        try await apiStatus(app, .POST, "/plans/\(plan.id.uuidString)/members", headers: authHeaders(owner), body: MemberBody(userID: editor.user.id))
        try await apiStatus(app, .DELETE, "/plans/\(plan.id.uuidString)/members/\(editor.user.id.uuidString)", headers: authHeaders(owner))

        let pull: SyncPullResponse = try await apiRequest(app, .GET, "/sync/pull", headers: authHeaders(editor))
        #expect(pull.plans.contains { $0.planID == plan.id && $0.revoked })
        try await app.asyncShutdown()
    
        })}
}
