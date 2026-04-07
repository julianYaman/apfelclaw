import Testing
@testable import ApfelClawCore

@Test
func appDirectoriesPointToExpectedLocations() throws {
    let directories = try AppDirectories()
    #expect(directories.configRoot.path.contains(".apfelclaw"))
}

@Test
func appVersionHeaderValueIncludesCurrentVersion() {
    #expect(AppVersion.current.isEmpty == false)
    #expect(AppVersion.serverHeaderValue == "apfelclaw-server/\(AppVersion.current)")
}
