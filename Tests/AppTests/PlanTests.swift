import Foundation
import MealPlannerCore
import Testing
import XCTVapor
import Vapor
@testable import App

@Suite(.serialized)
struct PlanTests {
    @Test("Creates a plan with entries and a shopping list")
    func createAndRead() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        _ = try await createRecipe(app, token: user)

        let plan = try await createPlan(app, token: user, days: 3)
        #expect(plan.entries.count == 3)
        #expect(plan.myRole == .owner)
        #expect(plan.members.count == 1)
        #expect(plan.shoppingList?.items.isEmpty == false)

        let fetched: PlanDTO = try await apiRequest(app, .GET, "/plans/\(plan.id.uuidString)", headers: authHeaders(user))
        #expect(fetched.entries.count == 3)
        try await app.asyncShutdown()
    
        })}

    @Test("Locked entries survive recalculation")
    func recalculatePreservesLocks() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        _ = try await createRecipe(app, token: user, title: "Soup")
        _ = try await createRecipe(app, token: user, title: "Salad")
        let plan = try await createPlan(app, token: user, days: 3)

        let key = PlanEntryKey(date: plan.entries[1].date, slot: plan.entries[1].slot)
        let lockedRecipeID = plan.entries[1].recipeID
        struct LockBody: Encodable { var locked = true }
        let locked: PlanDTO = try await apiRequest(
            app, .POST, "/plans/\(plan.id.uuidString)/entries/\(key.date.isoString)/\(key.slot.rawValue)/lock",
            headers: authHeaders(user), body: LockBody()
        )
        #expect(locked.entries.first { $0.date == key.date }?.isLocked == true)

        struct RecalculateBody: Encodable { var seed: UInt64 = 7 }
        let recalculated: PlanDTO = try await apiRequest(
            app, .POST, "/plans/\(plan.id.uuidString)/recalculate",
            headers: authHeaders(user), body: RecalculateBody()
        )
        #expect(recalculated.entries.first { $0.date == key.date }?.recipeID == lockedRecipeID)
        try await app.asyncShutdown()
    
        })}

    @Test("Changing a meal updates the plan and shopping list")
    func changeMeal() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        _ = try await createRecipe(app, token: user, title: "Soup")
        let other = try await createRecipe(app, token: user, title: "Salad")
        let plan = try await createPlan(app, token: user, days: 2)

        let key = PlanEntryKey(date: plan.entries[0].date, slot: plan.entries[0].slot)
        struct Body: Encodable { var recipeID: UUID; var servings = 4 }
        let updated: PlanDTO = try await apiRequest(
            app, .POST, "/plans/\(plan.id.uuidString)/entries/\(key.date.isoString)/\(key.slot.rawValue)",
            headers: authHeaders(user), body: Body(recipeID: other.id)
        )
        let entry = updated.entries.first { $0.date == key.date }
        #expect(entry?.recipeID == other.id)
        #expect(entry?.servings == 4)
        #expect(updated.shoppingList?.items.isEmpty == false)
        try await app.asyncShutdown()
    
        })}

    @Test("Viewer cannot change meals")
    func viewerCannotEdit() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let owner = try await signIn(app, email: "owner@example.com")
        let viewer = try await signIn(app, email: "viewer@example.com")
        _ = try await createRecipe(app, token: owner)
        let plan = try await createPlan(app, token: owner, days: 2)

        struct FriendBody: Encodable { var email: String }
        try await apiStatus(app, .POST, "/friends", headers: authHeaders(viewer), body: FriendBody(email: "owner@example.com"), expected: .accepted)
        try await apiStatus(app, .POST, "/friends/\(viewer.user.id.uuidString)/accept", headers: authHeaders(owner))

        struct MemberBody: Encodable { var userID: UUID; var role = PlanRole.viewer }
        try await apiStatus(
            app, .POST, "/plans/\(plan.id.uuidString)/members",
            headers: authHeaders(owner), body: MemberBody(userID: viewer.user.id)
        )

        let key = PlanEntryKey(date: plan.entries[0].date, slot: plan.entries[0].slot)
        struct Body: Encodable { var recipeID: UUID }
        try await apiStatus(
            app, .POST, "/plans/\(plan.id.uuidString)/entries/\(key.date.isoString)/\(key.slot.rawValue)",
            headers: authHeaders(viewer), body: Body(recipeID: plan.entries[0].recipeID), expected: .forbidden
        )
        try await app.asyncShutdown()
    
        })}

    @Test("Revoked member cannot read or push")
    func revocation() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let owner = try await signIn(app, email: "owner@example.com")
        let editor = try await signIn(app, email: "editor@example.com")
        _ = try await createRecipe(app, token: owner)
        let plan = try await createPlan(app, token: owner, days: 2)

        struct FriendBody: Encodable { var email: String }
        try await apiStatus(app, .POST, "/friends", headers: authHeaders(editor), body: FriendBody(email: "owner@example.com"), expected: .accepted)
        try await apiStatus(app, .POST, "/friends/\(editor.user.id.uuidString)/accept", headers: authHeaders(owner))

        struct MemberBody: Encodable { var userID: UUID; var role = PlanRole.editor }
        try await apiStatus(
            app, .POST, "/plans/\(plan.id.uuidString)/members",
            headers: authHeaders(owner), body: MemberBody(userID: editor.user.id)
        )
        try await apiStatus(
            app, .DELETE, "/plans/\(plan.id.uuidString)/members/\(editor.user.id.uuidString)",
            headers: authHeaders(owner)
        )
        try await apiStatus(app, .GET, "/plans/\(plan.id.uuidString)", headers: authHeaders(editor), expected: .forbidden)
        try await app.asyncShutdown()
    
        })}

    @Test("Shopping check-off is stored")
    func shoppingCheck() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        _ = try await createRecipe(app, token: user)
        let plan = try await createPlan(app, token: user, days: 2)
        let itemKey = plan.shoppingList!.items[0].key

        struct Body: Encodable { var itemKey: String; var isChecked = true }
        let list: ShoppingListDTO = try await apiRequest(
            app, .POST, "/plans/\(plan.id.uuidString)/shopping/check",
            headers: authHeaders(user), body: Body(itemKey: itemKey)
        )
        #expect(list.items.first { $0.key == itemKey }?.isChecked == true)
        try await app.asyncShutdown()
    
        })}

    @Test("Owner can delete a plan")
    func deletePlan() async throws {
        try await testGate.run(TestBody {
        let app = try await makeTestApp()
        try await resetDatabase(app)
        let user = try await signIn(app)
        _ = try await createRecipe(app, token: user)
        let plan = try await createPlan(app, token: user)

        try await apiStatus(app, .DELETE, "/plans/\(plan.id.uuidString)", headers: authHeaders(user), expected: .noContent)
        try await apiStatus(app, .GET, "/plans/\(plan.id.uuidString)", headers: authHeaders(user), expected: .notFound)
        try await app.asyncShutdown()
    
        })}
}
