import Darwin
import Foundation

/// One file from the archive table. Listing does not decompress the solid payload.
public struct FurlListedFile: Equatable, Sendable, Identifiable {
    public var path: String
    public var uncompressedSize: UInt64
    public var modified: Date
    public var mode: UInt16
    public var symlinkTarget: String?

    public var id: String { path }
    public var isSymlink: Bool { symlinkTarget != nil }

    public init(
        path: String,
        uncompressedSize: UInt64,
        modified: Date,
        mode: UInt16,
        symlinkTarget: String? = nil
    ) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.modified = modified
        self.mode = mode
        self.symlinkTarget = symlinkTarget
    }
}

public struct FurlListing: Equatable, Sendable {
    public var version: UInt8
    public var files: [FurlListedFile]
    public var compressedBytes: UInt64
    public var uncompressedBytes: UInt64

    public init(version: UInt8, files: [FurlListedFile], compressedBytes: UInt64, uncompressedBytes: UInt64) {
        self.version = version
        self.files = files
        self.compressedBytes = compressedBytes
        self.uncompressedBytes = uncompressedBytes
    }
}

public struct FurlEntry: Equatable, Sendable {
    public var path: String
    public var data: Data
    public var modified: Date?
    /// POSIX permission bits (`0o644`, `0o755`, …). `0` means “unknown” (v1 archives).
    public var mode: UInt16
    /// When set, this entry is a symlink; `data` is empty.
    public var symlinkTarget: String?

    public init(
        path: String,
        data: Data,
        modified: Date? = nil,
        mode: UInt16 = 0o644,
        symlinkTarget: String? = nil
    ) {
        self.path = path
        self.data = data
        self.modified = modified
        self.mode = mode
        self.symlinkTarget = symlinkTarget
    }
}

public enum FurlArchive {
    public static let fileExtension = "furl"
    public static let maxFiles = 65_535
    public static let maxPathBytes = 65_535
    /// Solid payload cap, matching the C codec’s 8 GiB ceiling.
    public static let maxSolidBytes = UInt64(8) << 30

    public static let containerVersion: UInt8 = 2
    private static let magic = Data("FURL".utf8)
    private static let kindFile: UInt8 = 0
    private static let kindSymlink: UInt8 = 1

    public static func pack(
        _ entries: [FurlEntry],
        level: Int = 7,
        progress: ((UInt64, UInt64) -> Bool)? = nil,
        parseReport: ((DensityReport) -> Void)? = nil
    ) throws -> Data {
        guard !entries.isEmpty else {
            throw FurlError.format("Nothing to furl.")
        }
        guard entries.count <= maxFiles else {
            throw FurlError.format("Too many files (\(entries.count)); maximum is \(maxFiles).")
        }

        var seen = Set<String>()
        var total: UInt64 = 0
        for entry in entries {
            try validatePath(entry.path)
            if !seen.insert(entry.path).inserted {
                throw FurlError.format("Duplicate path in archive: \(entry.path)")
            }
            total += UInt64(entry.data.count)
            guard total <= maxSolidBytes else {
                throw FurlError.format("Archive contents exceed \(maxSolidBytes) bytes. Furl 1.x holds the solid stream in memory.")
            }
        }

        /* Same idea as 7-Zip solid: group by extension then name so similar
           files sit in the same match window (e.g. two AppKit-*.pcm caches). */
        let ordered = solidSorted(entries)

        var table = Data()
        writeU16(&table, UInt16(ordered.count))
        var payload = Data()
        payload.reserveCapacity(Int(clamping: total))
        for entry in ordered {
            let isLink = entry.symlinkTarget != nil
            let name = Data(entry.path.utf8)
            writeU16(&table, UInt16(name.count))
            table.append(name)
            writeU64(&table, isLink ? 0 : UInt64(entry.data.count))
            writeU32(&table, isLink ? 0 : CRC32.hash(entry.data))
            writeU64(&table, encodeMtime(entry.modified ?? Date()))
            let mode = entry.mode == 0 ? UInt16(isLink ? 0o755 : 0o644) : entry.mode
            writeU16(&table, mode)
            writeU8(&table, isLink ? kindSymlink : kindFile)
            if let target = entry.symlinkTarget {
                let extra = Data(target.utf8)
                guard extra.count <= maxPathBytes, extra.firstIndex(of: 0) == nil, !target.isEmpty else {
                    throw FurlError.format("Invalid symlink target for \(entry.path).")
                }
                writeU16(&table, UInt16(extra.count))
                table.append(extra)
            } else {
                writeU16(&table, 0)
            }
            if !isLink {
                payload.append(entry.data)
            }
        }

        var fileEnds: [UInt64] = []
        fileEnds.reserveCapacity(ordered.count)
        var running: UInt64 = 0
        for entry in ordered where entry.symlinkTarget == nil {
            running += UInt64(entry.data.count)
            fileEnds.append(running)
        }
        let compressed = try FurlCodec.compress(payload, level: level, progress: progress, fileEnds: fileEnds, parseReport: parseReport)

        var out = Data()
        out.append(magic)
        out.append(containerVersion)
        out.append(1) // flags: solid
        writeU32(&out, UInt32(entries.count))
        writeU32(&out, 0) // reserved
        out.append(table)
        writeU64(&out, UInt64(compressed.count))
        out.append(compressed)
        return out
    }

    /// Read the file table. Does not decompress the solid payload.
    public static func catalog(_ archive: Data) throws -> FurlListing {
        let box = try readContainer(archive)
        let files = box.metas.map {
            FurlListedFile(
                path: $0.path,
                uncompressedSize: UInt64($0.size),
                modified: $0.modified,
                mode: $0.mode,
                symlinkTarget: $0.symlinkTarget
            )
        }
        let uncompressed = files.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        return FurlListing(
            version: box.version,
            files: files,
            compressedBytes: UInt64(box.payload.count),
            uncompressedBytes: uncompressed
        )
    }

    public static func unpack(
        _ archive: Data,
        progress: ((UInt64, UInt64) -> Bool)? = nil
    ) throws -> [FurlEntry] {
        let box = try readContainer(archive)
        let metas = box.metas
        let compressed = archive.subdata(in: box.payload)
        let payload = try FurlCodec.decompress(compressed, progress: progress)

        var entries: [FurlEntry] = []
        entries.reserveCapacity(metas.count)
        var offset = 0
        for meta in metas {
            if let target = meta.symlinkTarget {
                entries.append(FurlEntry(
                    path: meta.path,
                    data: Data(),
                    modified: meta.modified,
                    mode: meta.mode == 0 ? 0o755 : meta.mode,
                    symlinkTarget: target
                ))
                continue
            }
            guard meta.size >= 0, offset <= payload.count, payload.count - offset >= meta.size else {
                throw FurlError.format("Payload shorter than file table.")
            }
            let data = payload.subdata(in: offset..<(offset + meta.size))
            guard CRC32.hash(data) == meta.crc else {
                throw FurlError.format("Checksum failed for \(meta.path).")
            }
            var mode = meta.mode
            if mode == 0 {
                mode = looksExecutable(path: meta.path, data: data) ? 0o755 : 0o644
            }
            entries.append(FurlEntry(path: meta.path, data: data, modified: meta.modified, mode: mode))
            offset += meta.size
        }
        guard offset == payload.count else {
            throw FurlError.format("Payload longer than file table.")
        }
        return entries
    }

    private struct Meta {
        var path: String
        var size: Int
        var crc: UInt32
        var modified: Date
        var mode: UInt16
        var symlinkTarget: String?
    }

    private struct Container {
        var version: UInt8
        var metas: [Meta]
        var payload: Range<Int>
    }

    private static func readContainer(_ archive: Data) throws -> Container {
        var r = Cursor(archive)
        let mag = try r.bytes(4)
        guard mag == magic else {
            throw FurlError.format("Not a Furl archive.")
        }
        let version = try r.u8()
        guard version == 1 || version == 2 else {
            throw FurlError.format("Unsupported Furl version \(version).")
        }
        _ = try r.u8() // flags
        let nfiles = try r.u32Int(max: maxFiles, name: "file count")
        guard nfiles > 0 else {
            throw FurlError.format("Invalid file count.")
        }
        _ = try r.u32() // reserved

        let tableCount = try r.u16Int(max: maxFiles, name: "table count")
        guard tableCount == nfiles else {
            throw FurlError.format("File table does not match header.")
        }

        var metas: [Meta] = []
        var seen = Set<String>()
        var total: UInt64 = 0
        metas.reserveCapacity(nfiles)
        for _ in 0..<nfiles {
            let nameLen = try r.u16Int(max: maxPathBytes, name: "path length")
            let nameData = try r.bytes(nameLen)
            guard let path = String(data: nameData, encoding: .utf8), !path.isEmpty else {
                throw FurlError.format("Invalid path.")
            }
            try validatePath(path)
            if !seen.insert(path).inserted {
                throw FurlError.format("Duplicate path in archive: \(path)")
            }
            let size = try r.u64Int(name: "file size")
            let crc = try r.u32()
            let ts = try r.u64()
            var mode: UInt16 = 0
            var symlinkTarget: String? = nil
            if version >= 2 {
                mode = try r.u16()
                let kind = try r.u8()
                let extraLen = try r.u16Int(max: maxPathBytes, name: "extra length")
                let extra = extraLen > 0 ? try r.bytes(extraLen) : Data()
                if kind == kindSymlink {
                    guard size == 0, extraLen > 0,
                          let target = String(data: extra, encoding: .utf8), !target.isEmpty else {
                        throw FurlError.format("Invalid symlink entry: \(path)")
                    }
                    symlinkTarget = target
                } else if kind != kindFile {
                    throw FurlError.format("Unknown file kind \(kind) for \(path).")
                } else if extraLen != 0 {
                    throw FurlError.format("Unexpected extra data for \(path).")
                }
            }
            total += UInt64(size)
            guard total <= maxSolidBytes else {
                throw FurlError.format("Archive contents exceed \(maxSolidBytes) bytes.")
            }
            metas.append(Meta(
                path: path,
                size: size,
                crc: crc,
                modified: decodeMtime(ts),
                mode: mode,
                symlinkTarget: symlinkTarget
            ))
        }

        let clen = try r.u64Int(name: "compressed size")
        let start = r.i
        try r.need(clen, "bytes")
        r.i += clen
        if r.i != archive.count {
            throw FurlError.format("Archive has trailing bytes.")
        }
        return Container(version: version, metas: metas, payload: start..<r.i)
    }

    /// Write entries under `folder`, restoring modes, mtimes, and symlinks.
    /// Files are written before symlinks. A path is not allowed to descend through a symlink, whether that link is in the archive or already in `folder`.
    public static func writeEntries(_ entries: [FurlEntry], into folder: URL) throws {
        try rejectSymlinkTraversal(entries)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fm = FileManager.default
        let ordered = entries.filter { $0.symlinkTarget == nil } + entries.filter { $0.symlinkTarget != nil }
        for entry in ordered {
            let dest = try destination(in: folder, forRelative: entry.path)
            try makeParentDirectories(of: dest, root: folder, relative: entry.path)
            try replaceFinalComponent(at: dest)
            if let target = entry.symlinkTarget {
                try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: target)
                if let modified = entry.modified {
                    let sec = time_t(wholeSeconds(modified))
                    let times = [timeval(tv_sec: sec, tv_usec: 0), timeval(tv_sec: sec, tv_usec: 0)]
                    let rc = times.withUnsafeBufferPointer { buf in
                        lutimes(dest.path, buf.baseAddress)
                    }
                    if rc != 0 {
                        throw FurlError.format("Could not restore the modification time of \(entry.path).")
                    }
                }
                let bits = entry.mode == 0 ? UInt16(0o755) : (entry.mode & 0o7777)
                _ = lchmod(dest.path, mode_t(bits))
                continue
            }
            try entry.data.write(to: dest, options: .atomic)
            var attrs: [FileAttributeKey: Any] = [:]
            let mode: Int
            if entry.mode == 0 {
                mode = looksExecutable(path: entry.path, data: entry.data) ? 0o755 : 0o644
            } else {
                mode = Int(entry.mode) & 0o7777
            }
            attrs[.posixPermissions] = mode
            if let modified = entry.modified {
                attrs[.modificationDate] = modified
            }
            try fm.setAttributes(attrs, ofItemAtPath: dest.path)
        }
    }

    /// Whole seconds since 1970. A negative count is stored in the same 8 bytes.
    private static func wholeSeconds(_ date: Date) -> Int64 {
        let seconds = date.timeIntervalSince1970
        if seconds >= Double(Int64.max) { return Int64.max }
        if seconds <= Double(Int64.min) { return Int64.min }
        return Int64(seconds)
    }

    private static func encodeMtime(_ date: Date) -> UInt64 {
        UInt64(bitPattern: wholeSeconds(date))
    }

    private static func decodeMtime(_ ts: UInt64) -> Date {
        if ts > UInt64(Int64.max) {
            return Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: ts)))
        }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    public static func looksExecutable(path: String, data: Data) -> Bool {
        let lowered = path.lowercased()
        if lowered.contains("/contents/macos/") { return true }
        let name = lastPathComponent(lowered)
        if name.hasSuffix(".sh") || name.hasSuffix(".command") || name.hasSuffix(".dylib") {
            return true
        }
        if data.count >= 2, data[0] == 0x23, data[1] == 0x21 { return true }
        guard data.count >= 4 else { return false }
        let m0 = data[0], m1 = data[1], m2 = data[2], m3 = data[3]
        /* Mach-O thin + fat, either endian. */
        if m0 == 0xFE && m1 == 0xED && m2 == 0xFA && (m3 == 0xCE || m3 == 0xCF) { return true }
        if m0 == 0xCE && m1 == 0xFA && m2 == 0xED && m3 == 0xFE { return true }
        if m0 == 0xCF && m1 == 0xFA && m2 == 0xED && m3 == 0xFE { return true }
        if m0 == 0xCA && m1 == 0xFE && m2 == 0xBA && m3 == 0xBE { return true }
        if m0 == 0xBE && m1 == 0xBA && m2 == 0xFE && m3 == 0xCA { return true }
        return false
    }

    public static func validatePath(_ path: String) throws {
        guard !path.isEmpty else {
            throw FurlError.format("Empty path.")
        }
        if path.utf8.contains(0) {
            throw FurlError.format("Path contains a NUL.")
        }
        if path.contains("\\") {
            throw FurlError.format("Path contains a backslash: \(path)")
        }
        if path.hasPrefix("/") || path.hasPrefix("~") {
            throw FurlError.format("Path is not relative: \(path)")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else {
            throw FurlError.format("Empty path.")
        }
        for part in parts {
            if part.isEmpty {
                throw FurlError.format("Path has an empty segment: \(path)")
            }
            if part == "." || part == ".." {
                throw FurlError.format("Path contains a '\(part)' segment: \(path)")
            }
            if part.contains(":") {
                throw FurlError.format("Path contains a colon: \(path)")
            }
        }
        guard path.utf8.count <= maxPathBytes else {
            throw FurlError.format("Path too long: \(path)")
        }
    }

    static func solidSorted(_ entries: [FurlEntry]) -> [FurlEntry] {
        entries.sorted { a, b in
            let ea = solidExtension(a.path)
            let eb = solidExtension(b.path)
            if ea != eb { return ea < eb }
            let pa = solidPrefix(a.path)
            let pb = solidPrefix(b.path)
            if pa != pb { return pa < pb }
            if a.data.count != b.data.count { return a.data.count > b.data.count }
            let na = lastPathComponent(a.path).lowercased()
            let nb = lastPathComponent(b.path).lowercased()
            if na != nb { return na < nb }
            return a.path.lowercased() < b.path.lowercased()
        }
    }

    /// `AppKit-2VI8NB39.pcm` → `appkit` so the three module caches stay adjacent.
    private static func solidPrefix(_ path: String) -> String {
        var name = lastPathComponent(path)
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            name = String(name[..<dot])
        }
        if let dash = name.lastIndex(of: "-") {
            let tail = name[name.index(after: dash)...]
            if tail.count >= 6 {
                return String(name[..<dash]).lowercased()
            }
        }
        return name.lowercased()
    }

    private static func lastPathComponent(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[path.index(after: slash)...])
        }
        return path
    }

    private static func solidExtension(_ path: String) -> String {
        let name = lastPathComponent(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return ""
        }
        return name[name.index(after: dot)...].lowercased()
    }

    public static func isArchive(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == magic
    }

    public static func isArchive(url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// A file or link stored under a symlink entry would be written through that link.
    private static func rejectSymlinkTraversal(_ entries: [FurlEntry]) throws {
        let linkPaths = entries.compactMap { $0.symlinkTarget == nil ? nil : $0.path }
        for entry in entries {
            for link in linkPaths where entry.path.hasPrefix(link + "/") {
                throw FurlError.format("Path traverses a symlink: \(entry.path)")
            }
        }
    }

    /// Create each parent with `lstat` first, so an existing symlink is not followed.
    private static func makeParentDirectories(of dest: URL, root: URL, relative path: String) throws {
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        let parentPath = dest.deletingLastPathComponent().standardizedFileURL.path
        guard parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") else {
            throw FurlError.format("Path escapes destination: \(path)")
        }
        if parentPath == rootPath { return }
        let relativeParent = String(parentPath.dropFirst(rootPath.count + 1))
        var current = rootURL
        for part in relativeParent.split(separator: "/") {
            current.appendPathComponent(String(part), isDirectory: true)
            var st = stat()
            if lstat(current.path, &st) != 0 {
                if errno == ENOENT {
                    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                    continue
                }
                throw FurlError.format("Path escapes destination: \(path)")
            }
            let kind = st.st_mode & S_IFMT
            if kind == S_IFLNK {
                throw FurlError.format("Path traverses a symlink: \(path)")
            }
            if kind != S_IFDIR {
                throw FurlError.format("Path escapes destination: \(path)")
            }
        }
    }

    /// Remove whatever is at `dest` without following a final symlink.
    private static func replaceFinalComponent(at dest: URL) throws {
        var st = stat()
        if lstat(dest.path, &st) != 0 { return }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            if unlink(dest.path) != 0 {
                throw FurlError.format("Could not replace \(dest.lastPathComponent).")
            }
            return
        }
        try FileManager.default.removeItem(at: dest)
    }

    /// Join `path` under `folder`, rejecting anything that would leave `folder`.
    public static func destination(in folder: URL, forRelative path: String) throws -> URL {
        try validatePath(path)
        let root = folder.standardizedFileURL
        var url = root
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part), isDirectory: false)
        }
        let resolved = url.standardizedFileURL.path
        let rootPath = root.path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
            throw FurlError.format("Path escapes destination: \(path)")
        }
        return url.standardizedFileURL
    }
}

private struct Cursor {
    let data: Data
    var i = 0

    init(_ data: Data) { self.data = data }

    mutating func need(_ n: Int, _ what: String) throws {
        guard n >= 0, i >= 0, i <= data.count, data.count - i >= n else {
            throw FurlError.format("Truncated archive (\(what)).")
        }
    }

    mutating func u8() throws -> UInt8 {
        try need(1, "byte")
        let v = data[i]
        i += 1
        return v
    }

    mutating func u16() throws -> UInt16 {
        try need(2, "u16")
        let v = UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
        i += 2
        return v
    }

    mutating func u32() throws -> UInt32 {
        try need(4, "u32")
        let v = UInt32(data[i])
            | (UInt32(data[i + 1]) << 8)
            | (UInt32(data[i + 2]) << 16)
            | (UInt32(data[i + 3]) << 24)
        i += 4
        return v
    }

    mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32())
        let hi = UInt64(try u32())
        return lo | (hi << 32)
    }

    mutating func u16Int(max: Int, name: String) throws -> Int {
        let v = try u16()
        let n = Int(v)
        guard n <= max else {
            throw FurlError.format("Invalid \(name).")
        }
        return n
    }

    mutating func u32Int(max: Int, name: String) throws -> Int {
        let v = try u32()
        guard v <= UInt32(max) else {
            throw FurlError.format("Invalid \(name).")
        }
        return Int(v)
    }

    mutating func u64Int(name: String) throws -> Int {
        let v = try u64()
        guard v <= UInt64(Int.max) else {
            throw FurlError.format("Invalid \(name).")
        }
        return Int(v)
    }

    mutating func bytes(_ n: Int) throws -> Data {
        try need(n, "bytes")
        let slice = data.subdata(in: i..<(i + n))
        i += n
        return slice
    }
}

private func writeU8(_ data: inout Data, _ v: UInt8) {
    data.append(v)
}

private func writeU16(_ data: inout Data, _ v: UInt16) {
    data.append(UInt8(v & 0xFF))
    data.append(UInt8((v >> 8) & 0xFF))
}

private func writeU32(_ data: inout Data, _ v: UInt32) {
    data.append(UInt8(v & 0xFF))
    data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8((v >> 16) & 0xFF))
    data.append(UInt8((v >> 24) & 0xFF))
}

private func writeU64(_ data: inout Data, _ v: UInt64) {
    writeU32(&data, UInt32(truncatingIfNeeded: v))
    writeU32(&data, UInt32(truncatingIfNeeded: v >> 32))
}
