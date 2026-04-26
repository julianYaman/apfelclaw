import Foundation

public enum AppInstallSourceDetector {
    public static func detectCurrentInstallSource(
        executablePath: String = CommandLine.arguments[0]
    ) -> AppInstallSource {
        let resolved = URL(fileURLWithPath: executablePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        if resolved.contains("/Cellar/apfelclaw/") {
            return .homebrew
        }

        if resolved.hasSuffix("/apfelclaw") || resolved.contains("/.build/") {
            return .manual
        }

        return .unknown
    }
}
