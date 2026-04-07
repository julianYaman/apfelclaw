import Foundation

public final class MailTools: Sendable {
    public init() {}

    public func listRecentMail(limit: Int) throws -> String {
        let script = """
        const Mail = Application('Mail');
        const inbox = Mail.inbox();
        const messages = inbox.messages();
        const count = Math.min(\(limit), messages.length);
        const results = [];
        for (let i = 0; i < count; i++) {
          const message = messages[i];
          results.push({
            subject: message.subject(),
            sender: message.sender(),
            date_received: message.dateReceived() ? message.dateReceived().toISOString() : null,
            mailbox: inbox.name()
          });
        }
        JSON.stringify({ mailbox: inbox.name(), requested_limit: \(limit), returned_count: results.length, results });
        """

        let result = try CommandRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", "-e", script],
            timeout: 20
        )

        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError.message(stderr.isEmpty ? "Unable to read Apple Mail." : stderr)
        }

        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
