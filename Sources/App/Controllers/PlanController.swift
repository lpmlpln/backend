import Fluent
import Foundation
import MealPlannerCore
import Vapor

struct PlanController: Sendable {
    func register(routes: some RoutesBuilder) {
        routes.post("plans", use: create)
        routes.get("plans", use: list)
        routes.get("plans", ":planID", use: detail)
        routes.patch("plans", ":planID", use: update)
        routes.delete("plans", ":planID", use: delete)
        routes.post("plans", ":planID", "recalculate", use: recalculate)
        routes.post("plans", ":planID", "entries", ":date", ":slot", use: changeEntry)
        routes.post("plans", ":planID", "entries", ":date", ":slot", "lock", use: setLock)
        routes.post("plans", ":planID", "members", use: addMember)
        routes.delete("plans", ":planID", "members", ":userID", use: removeMember)
        routes.get("plans", ":planID", "shopping", use: shopping)
        routes.post("plans", ":planID", "shopping", "check", use: checkItem)
        routes.post("plans", ":planID", "shopping", "regenerate", use: regenerateShopping)
    }

    private func planning(_ request: Request) -> PlanningService {
        PlanningService(db: request.db, access: AccessPolicy(db: request.db))
    }

    private func planID(_ request: Request) throws -> UUID {
        guard let id = request.parameters.get("planID", as: UUID.self) else {
            throw AppError.notFound()
        }
        return id
    }

    @Sendable
    func create(_ request: Request) async throws -> PlanDTO {
        let userID = try request.requireUserID()
        let body = try request.content.decode(PlanCreateRequest.self)
        return try await planning(request).createPlan(userID: userID, request: body)
    }

    @Sendable
    func list(_ request: Request) async throws -> [PlanDTO] {
        let userID = try request.requireUserID()
        let plans = try await planning(request).accessiblePlans(userID: userID)
        var result: [PlanDTO] = []
        for plan in plans {
            guard let id = plan.id else { continue }
            result.append(try await planning(request).planDTO(planID: id, userID: userID))
        }
        return result
    }

    @Sendable
    func detail(_ request: Request) async throws -> PlanDTO {
        let userID = try request.requireUserID()
        return try await planning(request).planDTO(planID: try planID(request), userID: userID)
    }

    @Sendable
    func update(_ request: Request) async throws -> PlanDTO {
        let userID = try request.requireUserID()
        let body = try request.content.decode(PlanUpdateRequest.self)
        return try await planning(request).updatePlan(planID: try planID(request), userID: userID, request: body)
    }

    @Sendable
    func delete(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        try await planning(request).deletePlan(planID: try planID(request), userID: userID)
        return .noContent
    }

    @Sendable
    func recalculate(_ request: Request) async throws -> PlanDTO {
        let userID = try request.requireUserID()
        let body = try? request.content.decode(RecalculateRequest.self)
        return try await planning(request).recalculate(planID: try planID(request), userID: userID, seed: body?.seed)
    }

    @Sendable
    func changeEntry(_ request: Request) async throws -> PlanDTO {
        let userID = try request.requireUserID()
        guard let dateString = request.parameters.get("date"),
              let date = CalendarDate(isoString: dateString),
              let slotString = request.parameters.get("slot"),
              let slot = MealSlot(rawValue: slotString)
        else { throw AppError.validation("Invalid date or slot.") }
        let body = try request.content.decode(PlanEntryUpdateRequest.self)
        return try await planning(request).changeEntry(
            planID: try planID(request),
            userID: userID,
            key: PlanEntryKey(date: date, slot: slot),
            request: body
        )
    }

    @Sendable
    func setLock(_ request: Request) async throws -> PlanDTO {
        let userID = try request.requireUserID()
        guard let dateString = request.parameters.get("date"),
              let date = CalendarDate(isoString: dateString),
              let slotString = request.parameters.get("slot"),
              let slot = MealSlot(rawValue: slotString)
        else { throw AppError.validation("Invalid date or slot.") }
        let body = try request.content.decode(LockRequest.self)
        return try await planning(request).setLock(
            planID: try planID(request),
            userID: userID,
            key: PlanEntryKey(date: date, slot: slot),
            locked: body.locked
        )
    }

    @Sendable
    func addMember(_ request: Request) async throws -> PlanDTO {
        let userID = try request.requireUserID()
        let body = try request.content.decode(PlanMemberRequest.self)
        return try await planning(request).addMember(
            planID: try planID(request),
            userID: userID,
            memberID: body.userID,
            role: body.role
        )
    }

    @Sendable
    func removeMember(_ request: Request) async throws -> PlanDTO {
        let userID = try request.requireUserID()
        guard let memberID = request.parameters.get("userID", as: UUID.self) else {
            throw AppError.notFound()
        }
        return try await planning(request).removeMember(
            planID: try planID(request),
            userID: userID,
            memberID: memberID
        )
    }

    @Sendable
    func shopping(_ request: Request) async throws -> ShoppingListDTO {
        let userID = try request.requireUserID()
        return try await planning(request).shoppingDTO(planID: try planID(request), userID: userID)
            ?? ShoppingListDTO(planID: try planID(request), items: [])
    }

    @Sendable
    func checkItem(_ request: Request) async throws -> ShoppingListDTO {
        let userID = try request.requireUserID()
        let body = try request.content.decode(ShoppingCheckRequest.self)
        return try await planning(request).setChecked(
            planID: try planID(request),
            userID: userID,
            itemKey: body.itemKey,
            isChecked: body.isChecked
        )
    }

    @Sendable
    func regenerateShopping(_ request: Request) async throws -> ShoppingListDTO {
        let userID = try request.requireUserID()
        let id = try planID(request)
        try await planning(request).regenerateShoppingList(planID: id, userID: userID)
        return try await planning(request).shoppingDTO(planID: id, userID: userID)
            ?? ShoppingListDTO(planID: id, items: [])
    }
}

struct LockRequest: Codable, Sendable {
    var locked: Bool
}
