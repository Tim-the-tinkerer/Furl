import Foundation

public struct RaceResult: Sendable {
    public var originalBytes: Int
    public var furlBytes: Int
    public var furlSeconds: Double
    public var rivalBytes: Int?
    public var rivalSeconds: Double?
    public var rivalName: String
    /// True only when Furl is strictly smaller than 7-Zip (or the LZMA stand-in). Equal sizes are not a win.
    public var furlWon: Bool?
    public var level: Int
    public var zipBytes: Int?
    public var zipSeconds: Double?
    public var zipName: String

    public init(
        originalBytes: Int,
        furlBytes: Int,
        furlSeconds: Double,
        rivalBytes: Int?,
        rivalSeconds: Double?,
        rivalName: String,
        furlWon: Bool?,
        level: Int,
        zipBytes: Int?,
        zipSeconds: Double?,
        zipName: String
    ) {
        self.originalBytes = originalBytes
        self.furlBytes = furlBytes
        self.furlSeconds = furlSeconds
        self.rivalBytes = rivalBytes
        self.rivalSeconds = rivalSeconds
        self.rivalName = rivalName
        self.furlWon = furlWon
        self.level = level
        self.zipBytes = zipBytes
        self.zipSeconds = zipSeconds
        self.zipName = zipName
    }

    public var furlRatio: Double {
        originalBytes == 0 ? 0 : Double(furlBytes) / Double(originalBytes)
    }

    public var rivalRatio: Double? {
        guard let rivalBytes, originalBytes > 0 else { return nil }
        return Double(rivalBytes) / Double(originalBytes)
    }

    public var zipRatio: Double? {
        guard let zipBytes, originalBytes > 0 else { return nil }
        return Double(zipBytes) / Double(originalBytes)
    }

    /// Short label for the 7-Zip column. The full method stays in `rivalName`.
    public var rivalShortName: String {
        if rivalName.hasPrefix("7-Zip") { return "7-Zip" }
        if rivalName.contains("LZMA") { return "LZMA" }
        return "Rival"
    }

    /// Sole smallest archive, or "Tie" when two or more share that size.
    public var verdict: String {
        var sizes: [(String, Int)] = [("Furl", furlBytes)]
        if let zipBytes { sizes.append(("ZIP", zipBytes)) }
        if let rivalBytes { sizes.append((rivalShortName, rivalBytes)) }
        let best = sizes.map(\.1).min() ?? furlBytes
        let names = sizes.filter { $0.1 == best }.map(\.0)
        return names.count == 1 ? names[0] : "Tie"
    }

    /// Plain-text result. The window shows the same numbers; this is the saved copy.
    public var document: String {
        var lines = [
            "Furl race",
            "Density \(level)",
            "Original  \(originalBytes)",
            sized("Furl", bytes: furlBytes, seconds: furlSeconds, note: nil),
        ]
        if let zipBytes {
            lines.append(sized("ZIP", bytes: zipBytes, seconds: zipSeconds, note: zipName))
        } else {
            lines.append("ZIP  —  \(zipName)")
        }
        if let rivalBytes {
            lines.append(sized(rivalShortName, bytes: rivalBytes, seconds: rivalSeconds, note: rivalName))
        } else {
            lines.append("\(rivalShortName)  —  \(rivalName)")
        }
        lines.append("Smallest  \(verdict)")
        return lines.joined(separator: "\n") + "\n"
    }

    private func sized(_ label: String, bytes: Int, seconds: Double?, note: String?) -> String {
        let time = seconds.map { String(format: "%.2fs", $0) } ?? "—"
        let ratio = originalBytes == 0 ? 0 : Double(bytes) / Double(originalBytes)
        var text = "\(label)  \(bytes)  \(String(format: "%.1f%%", ratio * 100))  \(time)"
        if let note { text += "  \(note)" }
        return text
    }
}

public enum SevenZipRace {
    public static func sevenZipURL() -> URL? {
        executable(at: [
            "/opt/homebrew/bin/7z",
            "/opt/homebrew/bin/7zz",
            "/usr/local/bin/7z",
            "/usr/local/bin/7zz",
        ])
    }

    public static func zipURL() -> URL? {
        executable(at: [
            "/usr/bin/zip",
            "/opt/homebrew/bin/zip",
            "/usr/local/bin/zip",
        ])
    }

    /// `Notes/` → `Notes.race.txt` beside the folder. One file keeps its own name. Several items use `Archive.race.txt`.
    public static func reportURL(beside item: URL, isDirectory: Bool, single: Bool) -> URL {
        let base: String
        if !single {
            base = "Archive"
        } else if isDirectory {
            base = item.lastPathComponent
        } else {
            base = item.deletingPathExtension().lastPathComponent
        }
        return item.deletingLastPathComponent()
            .appendingPathComponent(base)
            .appendingPathExtension("race.txt")
    }

    public static func race(
        entries: [FurlEntry],
        level: Int = 9,
        progress: ((UInt64, UInt64) -> Bool)? = nil
    ) throws -> RaceResult {
        let original = entries.reduce(0) { $0 + $1.data.count }
        let t0 = Date()
        let furlData = try FurlArchive.pack(entries, level: level, progress: progress)
        let furlTime = Date().timeIntervalSince(t0)
        if let progress, !progress(0, 0) {
            throw FurlError.cancelled
        }

        let zipExe = zipURL()
        let sevenExe = sevenZipURL()
        var zipBytes: Int?
        var zipTime: Double?
        var zipName = "ZIP (not found)"
        var rivalBytes: Int?
        var rivalTime: Double?
        var rivalName = "7-Zip (not found)"

        if zipExe != nil || sevenExe != nil {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("furl-race-\(UUID().uuidString)", isDirectory: true)
            let payloadDir = tmp.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try FurlArchive.writeEntries(entries, into: payloadDir)

            if let zipExe {
                if let progress, !progress(0, 0) { throw FurlError.cancelled }
                let archive = tmp.appendingPathComponent("rival.zip")
                let t1 = Date()
                // Same flags as Scripts/benchmark.sh: stored sizes, no Apple extras.
                try run(
                    zipExe,
                    arguments: ["-r", "-X", "-9", "-q", archive.path, ".", "-x", "*.DS_Store", "-x", "*__MACOSX*"],
                    directory: payloadDir,
                    progress: progress,
                    failure: "ZIP failed to create an archive."
                )
                zipTime = Date().timeIntervalSince(t1)
                zipBytes = try fileBytes(archive)
                zipName = "ZIP -9"
            }

            if let sevenExe {
                if let progress, !progress(0, 0) { throw FurlError.cancelled }
                let archive = tmp.appendingPathComponent("rival.7z")
                let threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
                let t1 = Date()
                try run(
                    sevenExe,
                    arguments: ["a", "-t7z", "-mx=9", "-m0=lzma2", "-mmt=\(threads)", archive.path, "."],
                    directory: payloadDir,
                    progress: progress,
                    failure: "7-Zip failed to create an archive."
                )
                rivalTime = Date().timeIntervalSince(t1)
                rivalBytes = try fileBytes(archive)
                rivalName = "7-Zip ultra (LZMA2, \(threads) threads)"
            }
        }

        if sevenExe == nil {
            if let progress, !progress(0, 0) {
                throw FurlError.cancelled
            }
            let t1 = Date()
            let payload = entries.reduce(into: Data()) { $0.append($1.data) }
            let lz = try LZMAFallback.compress(payload) {
                progress?(0, 0) ?? true
            }
            rivalTime = Date().timeIntervalSince(t1)
            rivalBytes = lz.data.count
            rivalName = lz.threads > 1
                ? "LZMA (system, \(lz.threads) threads)"
                : "LZMA (system, 7-Zip not installed)"
        }

        let won: Bool? = rivalBytes.map { furlData.count < $0 }
        return RaceResult(
            originalBytes: original,
            furlBytes: furlData.count,
            furlSeconds: furlTime,
            rivalBytes: rivalBytes,
            rivalSeconds: rivalTime,
            rivalName: rivalName,
            furlWon: won,
            level: level,
            zipBytes: zipBytes,
            zipSeconds: zipTime,
            zipName: zipName
        )
    }

    private static func executable(at paths: [String]) -> URL? {
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func fileBytes(_ url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FurlError.sevenZip("\(url.lastPathComponent) was not written.")
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size]
        if let n = size as? Int { return n }
        if let n = size as? NSNumber { return Int(n.int64Value) }
        throw FurlError.sevenZip("Could not read the size of \(url.lastPathComponent).")
    }

    private static func run(
        _ exe: URL,
        arguments: [String],
        directory: URL,
        progress: ((UInt64, UInt64) -> Bool)?,
        failure: String
    ) throws {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = arguments
        proc.currentDirectoryURL = directory
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        if let progress {
            while proc.isRunning {
                if !progress(0, 0) {
                    proc.terminate()
                    proc.waitUntilExit()
                    throw FurlError.cancelled
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw FurlError.sevenZip(failure)
        }
    }
}
