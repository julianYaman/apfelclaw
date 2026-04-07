import Foundation

public struct MailMessageSnapshot: Sendable {
    public let subject: String
    public let sender: String
    public let dateReceived: String
    public let mailbox: String
}

public struct MailToolSnapshot: Sendable {
    public let requestedLimit: Int
    public let returnedCount: Int
    public let messages: [MailMessageSnapshot]
}

public struct LastToolFailure: Sendable {
    public let toolName: String
    public let message: String
}
