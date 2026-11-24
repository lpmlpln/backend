import Foundation
import MealPlannerCore
import Vapor

struct AppError: Error, AbortError, DebuggableError {
    let status: HTTPResponseStatus
    let code: APIErrorCode
    let message: String
    let details: [String: String]?

    init(_ code: APIErrorCode, status: HTTPResponseStatus, message: String, details: [String: String]? = nil) {
        self.code = code
        self.status = status
        self.message = message
        self.details = details
    }

    var reason: String { message }
    var identifier: String { code.rawValue }

    static func unauthorized(_ message: String = "Authentication required.") -> AppError {
        AppError(.unauthorized, status: .unauthorized, message: message)
    }

    static func forbidden(_ message: String = "You do not have access to this resource.") -> AppError {
        AppError(.forbidden, status: .forbidden, message: message)
    }

    static func notFound(_ message: String = "Resource not found.") -> AppError {
        AppError(.notFound, status: .notFound, message: message)
    }

    static func validation(_ message: String, details: [String: String]? = nil) -> AppError {
        AppError(.validation, status: .badRequest, message: message, details: details)
    }

    static func conflict(_ message: String) -> AppError {
        AppError(.conflict, status: .conflict, message: message)
    }

    static func roleInsufficient(_ message: String = "Your role does not allow this change.") -> AppError {
        AppError(.planRoleInsufficient, status: .forbidden, message: message)
    }

    static func accessRevoked(_ message: String = "You no longer have access to this plan.") -> AppError {
        AppError(.planAccessRevoked, status: .forbidden, message: message)
    }

    static func invalidState(_ message: String) -> AppError {
        AppError(.syncInvalidState, status: .badRequest, message: message)
    }

    static func rateLimited() -> AppError {
        AppError(.rateLimited, status: .tooManyRequests, message: "Too many requests. Try again later.")
    }

    static func importFailed(_ message: String) -> AppError {
        AppError(.importFailed, status: .unprocessableEntity, message: message)
    }

    static func server(_ message: String = "Something went wrong.") -> AppError {
        AppError(.serverError, status: .internalServerError, message: message)
    }
}

struct ErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let error as AppError {
            return makeResponse(error, request: request)
        } catch let error as any AbortError {
            let appError = AppError(
                .validation,
                status: error.status,
                message: error.reason
            )
            return makeResponse(appError, request: request)
        } catch is DecodingError {
            return makeResponse(.validation("Invalid request body."), request: request)
        } catch {
            request.logger.report(error: error)
            return makeResponse(.server(), request: request)
        }
    }

    private func makeResponse(_ error: AppError, request: Request) -> Response {
        let body = APIErrorBody(code: error.code, message: error.message, details: error.details)
        let response = Response(status: error.status)
        response.headers.contentType = .json
        if let data = try? JSONEncoder().encode(body) {
            response.body = .init(data: data)
        }
        return response
    }
}

struct RequestIDMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let id = request.headers.first(name: "X-Request-ID") ?? UUID().uuidString
        request.storage[RequestIDKey.self] = id
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Request-ID", value: id)
        return response
    }
}

enum RequestIDKey: StorageKey {
    typealias Value = String
}

extension Request {
    var requestID: String {
        storage[RequestIDKey.self] ?? "-"
    }
}
