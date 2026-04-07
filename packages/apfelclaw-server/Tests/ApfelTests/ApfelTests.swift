import Testing
@testable import ApfelClawCore

@Test
func safeCommandsArePresent() {
    #expect(SafeCommandRegistry.commands.contains { $0.name == "mdfind" })
}
