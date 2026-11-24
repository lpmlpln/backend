import Foundation
import Vapor

protocol EmailSender: Sendable {
    func sendMagicLink(to email: String, link: URL, client: String, logger: Logger) async throws
}

/// Logs the link instead of sending it. Used for local development and tests.
struct ConsoleEmailSender: EmailSender {
    func sendMagicLink(to email: String, link: URL, client: String, logger: Logger) async throws {
        logger.warning("MAGIC LINK for \(email) [\(client)]: \(link.absoluteString)")
    }
}

/// SMTP2GO HTTP API adapter. The API key is only ever read from the environment.
struct SMTP2GOEmailSender: EmailSender {
    let client: any Client
    let apiKey: String
    let from: String

    func sendMagicLink(to email: String, link: URL, client: String, logger: Logger) async throws {
        let shorten = client == "admin"
        let subject = shorten ? "MealPlanner admin sign in" : "Sign in to MealPlanner"
        let textBody = "Open this link to sign in:\n\(link.absoluteString)\n\nIf you did not request this, ignore this email."
        let htmlBody = "<p>Open this link to sign in:</p><p><a href=\"\(link.absoluteString)\">\(link.absoluteString)</a></p><p>If you did not request this, ignore this email.</p>"

        struct Payload: Content {
            var api_key: String
            var sender: String
            var to: [String]
            var subject: String
            var text_body: String
            var html_body: String
        }

        let payload = Payload(
            api_key: apiKey,
            sender: from,
            to: [email],
            subject: subject,
            text_body: textBody,
            html_body: htmlBody
        )

        let response = try await self.client.post(
            "https://api.smtp2go.com/v3/email/send",
            headers: ["Content-Type": "application/json"],
            content: payload
        ).get()

        guard (200..<300).contains(response.status.code) else {
            let body = response.body.map { String(buffer: $0) } ?? ""
            logger.error("SMTP2GO rejected the email: \(body)")
            throw AppError.server("Email delivery failed.")
        }
    }
}
