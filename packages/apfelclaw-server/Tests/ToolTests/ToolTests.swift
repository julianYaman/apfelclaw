import Testing
@testable import ApfelClawCore

@Test
func trustedReadonlySkipsPrompts() {
    let policy = ToolPolicy(approvalMode: .trustedReadonly)
    #expect(policy.requiresPrompt(for: "find_files") == false)
}
