import Foundation

/// What a config path *is* on disk, as opposed to how it was spelled.
///
/// Multi-account setups reach one directory or file through several
/// spellings: `~/.claude-work` and a symlink to it, a hand-typed
/// `~/.Codex-Work` on a case-insensitive volume, a `settings.json` symlinked
/// between two accounts, a Grok `hooks/` folder linked to another root's.
/// Comparing spellings then gets "is this the primary's file?" wrong, which
/// is how removing an extra directory could strip the primary's hooks.
public enum ConfigPathIdentity {
    /// `path` with every symlink resolved and every existing component in its
    /// on-disk spelling — macOS `realpath(3)` also restores the stored case on
    /// a case-insensitive volume, which is the case normalization. A path
    /// that does not exist (yet) keeps its missing tail as written below its
    /// deepest existing ancestor, and a dangling symlink is followed to where
    /// it points, so `extra/hooks/codeisland.json` inside a symlinked
    /// `hooks/` resolves to the linked folder before the file is ever written.
    public static func resolved(_ path: String) -> String {
        resolved(path, hops: 0)
    }

    /// Key for deciding that two spellings are the same file or directory:
    /// `resolved` plus Unicode NFC (APFS preserves either normalization form).
    public static func identity(of path: String) -> String {
        ClaudeConfigPaths.canonical(resolved(path))
    }

    /// Where a write meant for `path` has to land so that a symlink at `path`
    /// survives it: the link's final target, or `path` itself when it is not a
    /// symlink. `FileManager.createFile` and atomic `String.write` replace the
    /// file by renaming a temporary copy over it, which turns a symlinked
    /// `settings.json` (dotfiles, one file shared between accounts) into a
    /// detached regular file. Only the last component matters — a symlinked
    /// *directory* on the way is followed by the kernel anyway.
    public static func writeTarget(for path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return path
        }
        return resolved(path)
    }

    /// `FileManager.createFile` at `writeTarget(for: path)`: the same atomic
    /// replace as before, but a symlinked config file keeps its link.
    ///
    /// When the link's target cannot be written — a read-only store such as
    /// a Nix / home-manager generation, or a folder that is gone — the write
    /// falls back to what it always did and replaces the link itself, so the
    /// hooks still get installed. Keeping writable links is the only change.
    @discardableResult
    public static func write(_ data: Data, to path: String, fileManager: FileManager = .default) -> Bool {
        let target = writeTarget(for: path)
        if fileManager.createFile(atPath: target, contents: data) { return true }
        return target != path && fileManager.createFile(atPath: path, contents: data)
    }

    // MARK: - Resolution

    /// Symlink hops before a cycle is assumed (the kernel's own MAXSYMLINKS).
    private static let maxHops = 32

    private static func resolved(_ path: String, hops: Int) -> String {
        if let real = realPath(path) { return real }
        guard hops < maxHops, path.hasPrefix("/") else { return path }

        // A dangling symlink: realpath gives up, but the write would land at
        // its target, so that is what the path is.
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let parent = (path as NSString).deletingLastPathComponent
            let target = destination.hasPrefix("/") ? destination : parent + "/" + destination
            return resolved(lexicallyNormalized(target), hops: hops + 1)
        }

        // Nothing there (yet): resolve the deepest existing ancestor and keep
        // the missing tail as written.
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        let name = (path as NSString).lastPathComponent
        let base = resolved(parent, hops: hops)
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// `.` and `..` collapsed textually, for a relative symlink target joined
    /// onto its link's folder. Only used on paths `realpath` could not take.
    static func lexicallyNormalized(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }
}
