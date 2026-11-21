import Fluent
import Foundation
import MealPlannerCore
import Vapor

struct FriendController: Sendable {
    func register(routes: some RoutesBuilder) {
        routes.get("friends", use: list)
        routes.post("friends", use: requestFriend)
        routes.post("friends", ":userID", "accept", use: accept)
        routes.delete("friends", ":userID", use: decline)
    }

    private func relatedRequests(_ userID: UUID, on db: any Database) async throws -> [FriendRequestModel] {
        let all = try await FriendRequestModel.query(on: db).all()
        return all.filter { $0.$fromUser.id == userID || $0.$toUser.id == userID }
    }

    private func friendship(_ userA: UUID, _ userB: UUID, on db: any Database) async throws -> [FriendshipModel] {
        let all = try await FriendshipModel.query(on: db).all()
        return all.filter {
            ($0.$userA.id == userA && $0.$userB.id == userB)
                || ($0.$userA.id == userB && $0.$userB.id == userA)
        }
    }

    @Sendable
    func list(_ request: Request) async throws -> [FriendDTO] {
        let userID = try request.requireUserID()
        let requests = try await relatedRequests(userID, on: request.db)
        var result: [FriendDTO] = []

        for item in requests {
            let outgoing = item.$fromUser.id == userID
            let otherID = outgoing ? item.$toUser.id : item.$fromUser.id
            guard let other = try await UserModel.find(otherID, on: request.db) else { continue }
            let status: FriendStatus
            switch item.status {
            case "accepted": status = .accepted
            case "pending": status = outgoing ? .pendingOutgoing : .pendingIncoming
            default: continue
            }
            result.append(
                FriendDTO(
                    userID: otherID,
                    displayName: other.displayName,
                    email: other.email,
                    status: status,
                    requestedAt: item.createdAt ?? Date()
                )
            )
        }
        return result
    }

    @Sendable
    func requestFriend(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        let body = try request.content.decode(FriendRequest.self)
        let email = body.email.lowercased()
        guard let target = try await UserModel.query(on: request.db).filter(\.$email == email).first() else {
            // Do not disclose whether an account exists.
            return .accepted
        }
        guard let targetID = target.id, targetID != userID else { return .accepted }

        if try await AccessPolicy(db: request.db).areFriends(userID, targetID) {
            return .ok
        }

        let pending = try await relatedRequests(userID, on: request.db)
        let exists = pending.contains {
            $0.status == "pending"
                && (($0.$fromUser.id == userID && $0.$toUser.id == targetID)
                    || ($0.$fromUser.id == targetID && $0.$toUser.id == userID))
        }
        if !exists {
            try await FriendRequestModel(fromUserID: userID, toUserID: targetID).save(on: request.db)
        }
        return .accepted
    }

    @Sendable
    func accept(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        guard let otherID = request.parameters.get("userID", as: UUID.self) else {
            throw AppError.notFound()
        }
        let requests = try await relatedRequests(userID, on: request.db)
        guard let incoming = requests.first(where: {
            $0.status == "pending" && $0.$fromUser.id == otherID && $0.$toUser.id == userID
        }) else { throw AppError.notFound() }

        incoming.status = "accepted"
        incoming.respondedAt = Date()
        try await incoming.save(on: request.db)

        if try await friendship(userID, otherID, on: request.db).isEmpty {
            try await FriendshipModel(userAID: userID, userBID: otherID).save(on: request.db)
        }
        return .ok
    }

    @Sendable
    func decline(_ request: Request) async throws -> HTTPStatus {
        let userID = try request.requireUserID()
        guard let otherID = request.parameters.get("userID", as: UUID.self) else {
            throw AppError.notFound()
        }
        for item in try await relatedRequests(userID, on: request.db)
            where (item.$fromUser.id == userID && item.$toUser.id == otherID)
                || (item.$fromUser.id == otherID && item.$toUser.id == userID) {
            item.status = "declined"
            item.respondedAt = Date()
            try await item.save(on: request.db)
        }
        for existing in try await friendship(userID, otherID, on: request.db) {
            try await existing.delete(on: request.db)
        }
        return .noContent
    }
}

struct SyncController: Sendable {
    func register(routes: some RoutesBuilder) {
        routes.get("sync", "pull", use: pull)
        routes.post("sync", "push", use: push)
    }

    private func sync(_ request: Request) -> SyncService {
        let access = AccessPolicy(db: request.db)
        return SyncService(
            db: request.db,
            access: access,
            planning: PlanningService(db: request.db, access: access)
        )
    }

    @Sendable
    func pull(_ request: Request) async throws -> SyncPullResponse {
        try await sync(request).pull(userID: request.requireUserID(), cursor: request.query[String.self, at: "cursor"])
    }

    @Sendable
    func push(_ request: Request) async throws -> SyncPushResponse {
        let body = try request.content.decode(SyncPushRequest.self)
        return try await sync(request).push(userID: request.requireUserID(), request: body)
    }
}
