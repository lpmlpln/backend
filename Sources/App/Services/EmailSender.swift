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
    let apiKey: String
    let from: String

    func sendMagicLink(to email: String, link: URL, client: String, logger: Logger) async throws {
        guard let url = URL(string: "https://api.smtp2go.com/v3/email/send") else {
            throw AppError.server("Invalid SMTP2GO endpoint.")
        }

        let shorten = client == "admin"
        let subject = shorten ? "MealPlanner admin sign in" : "Sign in to MealPlanner"
        let textBody = "Open this link to sign in:\n\(link.absoluteString)\n\nIf you did not request this, ignore this email."
        let htmlBody = "<p>Open this link to sign in:</p><p><a href=\"\(link.absoluteString)\">\(link.absoluteString)</a></p><p>If you did not request this, ignore this email.</p>"

        let payload: [String: Any] = [
            "api_key": apiKey,
            "sender": from,
            "to": [email],
            "subject": subject,
            "text_body": textBody,
            "html_body": htmlBody,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            logger.error("SMTP2GO rejected the email: \(String(data: data, encoding: .utf8) ?? "")")
            throw AppError.server("Email delivery failed.")
        }
    }
}
