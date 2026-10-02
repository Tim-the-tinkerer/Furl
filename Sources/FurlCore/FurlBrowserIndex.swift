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
        let prefix = folder.split(separator: "/").map(String.init)
        struct Acc {
            var isDirectory = false
            var size: UInt64 = 0
            var modified: Date?
            var file: FurlListedFile?
        }
        var rows: [String: Acc] = [:]
        for file in files {
            let parts = file.path.split(separator: "/").map(String.init)
            guard parts.count > prefix.count, Array(parts.prefix(prefix.count)) == prefix else { continue }
            let name = parts[prefix.count]
            let path = folder.isEmpty ? name : folder + "/" + name
            var acc = rows[path] ?? Acc()
            if parts.count == prefix.count + 1 {
                acc.file = file
            } else {
                acc.isDirectory = true
                acc.size += file.uncompressedSize
                let modified = file.modified
                if acc.modified.map({ modified > $0 }) ?? true {
                    acc.modified = modified
                }
            }
            rows[path] = acc
        }
        let built = rows.map { path, acc -> FurlBrowserRow in
            let name = path.split(separator: "/").last.map(String.init) ?? path
            if acc.isDirectory {
                return FurlBrowserRow(
                    name: name,
                    path: path,
                    isDirectory: true,
                    uncompressedSize: acc.size,
                    modified: acc.modified,
                    isSymlink: false
                )
            }
            let file = acc.file
            return FurlBrowserRow(
                name: name,
                path: path,
                isDirectory: false,
                uncompressedSize: file?.isSymlink == true ? 0 : (file?.uncompressedSize ?? 0),
                modified: file?.modified,
                isSymlink: file?.isSymlink ?? false
            )
        }
        return built.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
