import Foundation

public enum ToolPermissionDecision: String, Sendable {
    case allow
    case deny
}

public struct ToolPolicy: Sendable {
    public let approvalMode: ApprovalMode

    public init(approvalMode: ApprovalMode) {
        self.approvalMode = approvalMode
    }

    public func requiresPrompt(for toolName: String) -> Bool {
        switch approvalMode {
        case .always:
            return true
        case .askOncePerToolPerSession:
            return true
        case .trustedReadonly:
            return false
        }
    }
}
