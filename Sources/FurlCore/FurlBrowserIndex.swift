import Foundation

public struct FurlBrowserRow: Equatable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var uncompressedSize: UInt64
    public var modified: Date?
    public var isSymlink: Bool

    public var id: String { path }

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        uncompressedSize: UInt64,
        modified: Date?,
        isSymlink: Bool
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.uncompressedSize = uncompressedSize
        self.modified = modified
        self.isSymlink = isSymlink
    }
}

public enum FurlBrowserIndex {
    /// `folder` is empty at the archive root, or a path without a trailing slash.
    public static func children(of folder: String, in files: [FurlListedFile]) -> [FurlBrowserRow] {
        var rows: [String: FurlBrowserRow] = [:]
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            let prefix = folder.split(separator: "/").map(String.init)
            guard parts.count > prefix.count, Array(parts.prefix(prefix.count)) == prefix else { continue }
            let name = parts[prefix.count]
            let isLast = parts.count == prefix.count + 1
            let path = folder.isEmpty ? name : folder + "/" + name
            if isLast {
                if rows[path]?.isDirectory == true {
                    continue
                }
                rows[path] = FurlBrowserRow(
                    name: name,
                    path: path,
                    isDirectory: false,
                    uncompressedSize: file.isSymlink ? 0 : file.uncompressedSize,
                    modified: file.modified,
                    isSymlink: file.isSymlink
                )
            } else if var existing = rows[path], existing.isDirectory {
                existing.uncompressedSize += file.uncompressedSize
                if let modified = file.modified, existing.modified.map({ modified > $0 }) ?? true {
                    existing.modified = modified
                }
                rows[path] = existing
            } else if rows[path] == nil {
                rows[path] = FurlBrowserRow(
                    name: name,
                    path: path,
                    isDirectory: true,
                    uncompressedSize: file.uncompressedSize,
                    modified: file.modified,
                    isSymlink: false
                )
            }
        }
        return rows.values.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
