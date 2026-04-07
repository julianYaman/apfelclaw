import Testing
@testable import ApfelClawCore

@Test
func configModelPersistsFields() {
    let config = AppConfig(
        assistantName: "Apfelclaw",
        userName: "Yaman",
        approvalMode: .always,
        debug: false,
        memoryEnabled: true
    )
    #expect(config.assistantName == "Apfelclaw")
    #expect(config.memoryEnabled)
    #expect(config.debug == false)
}
