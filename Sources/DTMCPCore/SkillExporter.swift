import Foundation

/// The agent skill that ships inside the app, and a way to copy it where an agent harness can load it.
public enum SkillExporter {
    public static let skillName = "drawthings-mcp"

    public enum SkillError: Error, LocalizedError {
        case missing
        public var errorDescription: String? { "The bundled skill files could not be found." }
    }

    /// The folder inside the app bundle that holds SKILL.md and any reference files.
    public static func bundledFolder() throws -> URL {
        guard
            let url = Bundle.module.url(forResource: skillName, withExtension: nil, subdirectory: "skill"),
            FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path)
        else { throw SkillError.missing }
        return url
    }

    public static func skillText() throws -> String {
        try String(contentsOf: bundledFolder().appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    /// Copies the skill folder into `destination` as `<destination>/drawthings-mcp`, replacing an
    /// earlier copy. Returns the new folder.
    @discardableResult
    public static func export(to destination: URL) throws -> URL {
        let source = try bundledFolder()
        let target = destination.appendingPathComponent(skillName, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
        return target
    }
}
