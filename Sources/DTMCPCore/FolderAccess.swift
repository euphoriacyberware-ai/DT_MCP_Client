import Foundation

/// Security-scoped folder grants for the App Sandbox. The user picks folders in an open panel;
/// we persist bookmarks and re-open access on launch. Agents may only read inputs from, and the
/// app only writes outputs to, folders the user granted.
public actor FolderAccess {
    public enum Role: String, Codable, Sendable { case output, input }

    public struct Grant: Codable, Sendable, Identifiable, Hashable {
        public var id: UUID
        public var role: Role
        public var path: String
        var bookmark: Data
    }

    public enum AccessError: Error, LocalizedError {
        case noOutputFolder
        case notGranted(String)
        case staleBookmark(String)

        public var errorDescription: String? {
            switch self {
            case .noOutputFolder:
                return "No output folder is configured. Ask the user to choose an output folder in the DT MCP Client app."
            case .notGranted(let p):
                return "Path '\(p)' is outside the folders the user has granted. Ask the user to add its folder under Input Folders in the DT MCP Client app."
            case .staleBookmark(let p):
                return "Access to '\(p)' has expired. Ask the user to re-select the folder in the DT MCP Client app."
            }
        }
    }

    private let defaults: UserDefaults
    private let key: String
    private var grants: [Grant] = []
    /// URLs currently open for security-scoped access, by grant id.
    private var open: [UUID: URL] = [:]

    public init(defaults: UserDefaults = .standard, key: String = "folderGrants") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([Grant].self, from: data)
        {
            grants = decoded
        }
    }

    private var opened = false
    /// Re-opens persisted bookmarks once, on first use (actor inits can't call isolated methods).
    private func openPersisted() {
        guard !opened else { return }
        opened = true
        for g in grants { _ = resolveAndOpen(g) }
    }

    // MARK: Granting

    /// Records a user-selected folder. Replaces any existing output grant.
    @discardableResult
    public func grant(_ url: URL, role: Role) throws -> Grant {
        openPersisted()
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        if role == .output {
            for old in grants where old.role == .output { close(old.id) }
            grants.removeAll { $0.role == .output }
        }
        let g = Grant(id: UUID(), role: role, path: Self.canonical(url), bookmark: bookmark)
        grants.append(g)
        _ = resolveAndOpen(g)
        persist()
        return g
    }

    public func revoke(_ id: UUID) {
        close(id)
        grants.removeAll { $0.id == id }
        persist()
    }

    public func allGrants() -> [Grant] { openPersisted(); return grants }

    // MARK: Using

    public func outputFolder() throws -> URL {
        openPersisted()
        guard let g = grants.first(where: { $0.role == .output }) else {
            throw AccessError.noOutputFolder
        }
        guard open[g.id] != nil else { throw AccessError.staleBookmark(g.path) }
        return URL(fileURLWithPath: g.path, isDirectory: true)
    }

    /// Validates that `path` is inside a granted input or output folder and returns a canonical URL.
    public func authorizedReadURL(_ path: String) throws -> URL {
        openPersisted()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let canon = Self.canonical(url)
        for g in grants where open[g.id] != nil {
            if canon == g.path || canon.hasPrefix(g.path + "/") {
                return URL(fileURLWithPath: canon)
            }
        }
        throw AccessError.notGranted(path)
    }

    // MARK: Internals

    private func resolveAndOpen(_ g: Grant) -> Bool {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: g.bookmark, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &stale),
            !stale, url.startAccessingSecurityScopedResource()
        else { return false }
        open[g.id] = url
        return true
    }

    private func close(_ id: UUID) {
        open.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(grants) { defaults.set(data, forKey: key) }
    }

    /// Resolves symlinks and `..` so path-prefix checks can't be bypassed.
    static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
