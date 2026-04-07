import Foundation
import Testing
@testable import ApfelClawCore

@Test
func configServiceReadsPersistedEditableConfig() async throws {
    let harness = try ConfigTestHarness()
    let service = try harness.makeService(
        defaults: AppConfig(
            assistantName: "Apfelclaw",
            userName: "Yaman",
            approvalMode: .always,
            debug: true,
            memoryEnabled: true
        )
    )

    let config = await service.current()

    #expect(config.assistantName == "Apfelclaw")
    #expect(config.userName == "Yaman")
    #expect(config.approvalMode == ApprovalMode.always.rawValue)
    #expect(config.debug == true)
}

@Test
func configServiceUpdatesValidEditableFields() async throws {
    let harness = try ConfigTestHarness()
    let service = try harness.makeService()

    let updated = try await service.update(
        EditableAppConfigUpdate(
            assistantName: "  Local Guide  ",
            userName: "  Casey  ",
            approvalMode: ApprovalMode.askOncePerToolPerSession.rawValue,
            debug: true
        )
    )

    #expect(updated.assistantName == "Local Guide")
    #expect(updated.userName == "Casey")
    #expect(updated.approvalMode == ApprovalMode.askOncePerToolPerSession.rawValue)
    #expect(updated.debug == true)
}

@Test
func configServiceRejectsInvalidApprovalMode() async throws {
    let harness = try ConfigTestHarness()
    let service = try harness.makeService()

    do {
        _ = try await service.update(EditableAppConfigUpdate(approvalMode: "never"))
        Issue.record("Expected invalid approvalMode to be rejected.")
    } catch {
        #expect(error.localizedDescription.contains("Invalid approvalMode"))
    }
}

@Test
func configServiceRejectsEmptyNames() async throws {
    let harness = try ConfigTestHarness()
    let service = try harness.makeService()

    do {
        _ = try await service.update(EditableAppConfigUpdate(assistantName: "   "))
        Issue.record("Expected empty assistantName to be rejected.")
    } catch {
        #expect(error.localizedDescription.contains("'assistantName' cannot be empty"))
    }
}

@Test
func configServicePersistsUpdatesAcrossReloads() async throws {
    let harness = try ConfigTestHarness()
    let initialService = try harness.makeService()

    _ = try await initialService.update(
        EditableAppConfigUpdate(
            assistantName: "Orbit",
            userName: "Riley",
            approvalMode: ApprovalMode.trustedReadonly.rawValue,
            debug: true
        )
    )

    let reloadedService = try harness.makeService()
    let reloaded = await reloadedService.current()

    #expect(reloaded.assistantName == "Orbit")
    #expect(reloaded.userName == "Riley")
    #expect(reloaded.approvalMode == ApprovalMode.trustedReadonly.rawValue)
    #expect(reloaded.debug == true)
    #expect(FileManager.default.fileExists(atPath: harness.configURL.path))
}

@Test
func configServiceLoadsLegacyConfigWithoutDebugField() async throws {
    let harness = try ConfigTestHarness()
    let legacyJSON = """
    {
      "assistantName": "Apfelclaw",
      "userName": "You",
      "approvalMode": "trusted-readonly",
      "memoryEnabled": true,
      "defaultCalendarScope": "all-visible",
      "terminalToolsEnabled": true,
      "apfelAutostartEnabled": true
    }
    """
    try Data(legacyJSON.utf8).write(to: harness.configURL, options: [.atomic])

    let service = try harness.makeService()
    let config = await service.current()

    #expect(config.assistantName == "Apfelclaw")
    #expect(config.debug == false)
}

private struct ConfigTestHarness {
    let root: URL
    let directories: AppDirectories
    let settingsStore: SettingsStore
    let configURL: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        self.directories = try AppDirectories(homeDirectory: root)
        try directories.bootstrap()
        self.settingsStore = SettingsStore(directories: directories)
        self.configURL = settingsStore.configURL
    }

    func makeService(defaults: AppConfig = .default) throws -> ConfigService {
        try ConfigService(settingsStore: settingsStore, defaults: defaults)
    }
}
