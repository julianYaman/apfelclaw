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

    public func requiresPrompt(for tool: ToolDefinition, priorApprovalExists: Bool) -> Bool {
        if tool.requiresConfirmation {
            return true
        }

        switch approvalMode {
        case .always:
            return true
        case .askOncePerToolPerSession:
            return priorApprovalExists == false
        case .trustedReadonly:
            return tool.readonly == false
        }
    }
}
