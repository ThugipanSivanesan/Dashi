import Foundation

/// Reads a local credential file defensively.
///
/// Both subscription readers point at a plain JSON file another tool writes (`~/.codex/auth.json`,
/// `~/.claude/.credentials.json`, or `$CODEX_HOME/auth.json`). This guards those reads so Dashi only
/// ever slurps a real, reasonably-sized *regular* file — never a symlink, directory, device node, or
/// oversized file swapped in via a manipulated environment/path. A missing or unsuitable file yields
/// `nil`, which callers already map to "not signed in". These paths (including `CODEX_HOME`) remain
/// trusted local configuration; this is defense-in-depth, not a trust boundary.
enum CredentialFile {
    /// Upper bound for these small OAuth JSON files; anything larger is treated as unusable.
    static let maxBytes = 1 << 20  // 1 MiB

    /// Returns the file's contents only when it is an existing, non-symlink, regular file within the
    /// size cap; otherwise `nil`.
    static func read(at url: URL) -> Data? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
            values.isSymbolicLink != true,
            values.isRegularFile == true,
            let size = values.fileSize, size <= maxBytes
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
