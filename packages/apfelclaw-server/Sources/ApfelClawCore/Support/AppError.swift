import Foundation

public enum AppError: LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}
