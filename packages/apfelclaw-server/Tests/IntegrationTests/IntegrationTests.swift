import Foundation
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
    #expect(AppVersion.serverHeaderValue == "apfelclaw/\(AppVersion.current)")
}

@Test
func installStateStorePersistsOnboardingCompletion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directories = try AppDirectories(homeDirectory: root)
    try directories.bootstrap()
    let store = InstallStateStore(directories: directories)

    let state = try store.markOnboardingCompleted(installSource: AppInstallSource.manual)
    let reloaded = try store.load()

    #expect(state.onboardingCompleted == true)
    #expect(reloaded?.onboardingCompleted == true)
    #expect(reloaded?.installSource == .manual)
}
