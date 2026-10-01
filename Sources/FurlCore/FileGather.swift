import Darwin
import Foundation

public enum FileGather {
    public struct Options: Equatable, Sendable {
        public var skipAppleDouble: Bool
        public var skipMacOSXFolder: Bool
        public var skipDSStore: Bool
        public var skipResourceFork: Bool

        public static let `default` = Options()

        public init(
            skipAppleDouble: Bool = true,
            skipMacOSXFolder: Bool = true,
            skipDSStore: Bool = true,
            skipResourceFork: Bool = true
        ) {
            self.skipAppleDouble = skipAppleDouble
            self.skipMacOSXFolder = skipMacOSXFolder
            self.skipDSStore = skipDSStore
            self.skipResourceFork = skipResourceFork
        }
    }

    public static func entries(from urls: [URL], options: Options = .default) throws -> [FurlEntry] {
        let roots = uniqueRoots(urls).filter { !shouldSkip($0, options: options) }
        guard !roots.isEmpty else {
            throw FurlError.format("No files to furl.")
        }
        let labels = uniqueLabels(for: roots)
        var out: [FurlEntry] = []
        for (root, label) in zip(roots, labels) {
            try append(url: root, root: root, label: roots.count == 1 ? nil : label, options: options, into: &out)
        }
        guard !out.isEmpty else {
            throw FurlError.format("No files to furl.")
        }
        var seen = Set<String>()
        for entry in out {
            try FurlArchive.validatePath(entry.path)
            if !seen.insert(entry.path).inserted {
                throw FurlError.format("Duplicate path in archive: \(entry.path)")
            }
        }
        return out
    }

    public static func shouldSkip(_ url: URL, options: Options = .default) -> Bool {
        let name = url.lastPathComponent
        if options.skipDSStore, name.caseInsensitiveCompare(".DS_Store") == .orderedSame {
            return true
        }
        if options.skipAppleDouble, isAppleDoubleName(name) {
            return true
        }
        if options.skipMacOSXFolder, name.caseInsensitiveCompare("__MACOSX") == .orderedSame {
            return true
        }
        if options.skipResourceFork, isResourceForkURL(url) {
            return true
        }
        return false
    }

    /// AppleDouble sidecar: `._file` next to `file`.
    public static func isAppleDoubleName(_ name: String) -> Bool {
        name.hasPrefix("._")
    }

    public static func isResourceForkURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.hasSuffix("/..namedfork/rsrc") || path.contains("/..namedfork/rsrc") {
            return true
        }
        let parts = url.pathComponents
        if let i = parts.firstIndex(of: "..namedfork"), i + 1 < parts.count, parts[i + 1] == "rsrc" {
            return true
        }
        return false
    }

    private static func uniqueRoots(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var roots: [URL] = []
        for url in urls {
            let std = url.standardizedFileURL
            if seen.insert(std.path).inserted {
                roots.append(std)
            }
        }
        return roots
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func baseLabel(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name.isEmpty {
            return isDirectory(url) ? "folder" : "file"
        }
        return name
    }

    /// `notes.txt` then `notes-2.txt`. A leading-dot name stays intact (`.gitignore` → `.gitignore-2`).
    private static func disambiguatedName(_ name: String, used: inout Set<String>) -> String {
        if used.insert(name).inserted {
            return name
        }
        let stem: String
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            ext = String(name[dot...])
        } else {
            stem = name
            ext = ""
        }
        var n = 2
        while true {
            let candidate = "\(stem)-\(n)\(ext)"
            if used.insert(candidate).inserted {
                return candidate
            }
            n += 1
        }
    }

    private static func uniqueLabels(for roots: [URL]) -> [String] {
        var used = Set<String>()
        return roots.map { url in
            let name = baseLabel(url)
            if isDirectory(url) {
                var candidate = name
                var n = 2
                while !used.insert(candidate).inserted {
                    candidate = "\(name)-\(n)"
                    n += 1
                }
                return candidate
            }
            return disambiguatedName(name, used: &used)
        }
    }

    private static func append(
        url: URL,
        root: URL,
        label: String?,
        options: Options,
        into out: inout [FurlEntry]
    ) throws {
        if shouldSkip(url, options: options) { return }
        let values = try url.resourceValues(forKeys: [
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .contentModificationDateKey,
        ])
        let mode = posixMode(of: url)
        if values.isSymbolicLink == true {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            guard !target.isEmpty, target.utf8.count <= FurlArchive.maxPathBytes, !target.utf8.contains(0) else {
                throw FurlError.format("Invalid symlink: \(url.path)")
            }
            let rel = archivePath(url, root: root, label: label)
            out.append(FurlEntry(
                path: rel,
                data: Data(),
                modified: values.contentModificationDate,
                mode: mode == 0 ? 0o755 : mode,
                symlinkTarget: target
            ))
            return
        }
        if values.isDirectory == true {
            let kids = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [
                    .isSymbolicLinkKey,
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .contentModificationDateKey,
                ],
                options: []
            )
            for kid in kids.sorted(by: { $0.path < $1.path }) {
                try append(url: kid, root: root, label: label, options: options, into: &out)
            }
            return
        }
        guard values.isRegularFile == true else { return }
        let data = try readDataFork(url, skipResourceFork: options.skipResourceFork)
        let rel = archivePath(url, root: root, label: label)
        out.append(FurlEntry(path: rel, data: data, modified: values.contentModificationDate, mode: mode == 0 ? 0o644 : mode))
    }

    /// Data fork only. Resource forks live in `com.apple.ResourceFork` / `..namedfork/rsrc`
    /// and are not part of a Furl payload when `skipResourceFork` is on.
    private static func readDataFork(_ url: URL, skipResourceFork: Bool) throws -> Data {
        if skipResourceFork, isResourceForkURL(url) {
            return Data()
        }
        if skipResourceFork {
            let dataFork = URL(fileURLWithPath: url.path + "/..namedfork/data")
            if FileManager.default.fileExists(atPath: dataFork.path) {
                return try Data(contentsOf: dataFork)
            }
        }
        return try Data(contentsOf: url)
    }

    private static func posixMode(of url: URL) -> UInt16 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0o644 }
        return UInt16(st.st_mode & 0o7777)
    }

    private static func relativeRest(_ url: URL, root: URL) -> String {
        let rootPath = root.path
        let path = url.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        // /tmp and /private/tmp are the same directory. Child URLs sometimes
        // use one spelling and the root the other, which used to collapse
        // every file to its bare name.
        let stdRoot = root.standardizedFileURL.path
        let stdPath = url.standardizedFileURL.path
        if stdPath.hasPrefix(stdRoot + "/") {
            return String(stdPath.dropFirst(stdRoot.count + 1))
        }
        return url.lastPathComponent
    }

    private static func archivePath(_ url: URL, root: URL, label: String?) -> String {
        if !isDirectory(root) {
            return label ?? url.lastPathComponent
        }
        let rest = relativeRest(url, root: root)
        let head = label ?? root.lastPathComponent
        return rest.isEmpty ? head : head + "/" + rest
    }
}
