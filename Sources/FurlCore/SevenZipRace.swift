import Foundation

public struct RaceResult: Sendable {
    public var originalBytes: Int
    public var furlBytes: Int
    public var furlSeconds: Double
    public var rivalBytes: Int?
    public var rivalSeconds: Double?
    public var rivalName: String
    public var furlWon: Bool?

    public var furlRatio: Double {
        originalBytes == 0 ? 0 : Double(furlBytes) / Double(originalBytes)
    }

    public var rivalRatio: Double? {
        guard let rivalBytes, originalBytes > 0 else { return nil }
        return Double(rivalBytes) / Double(originalBytes)
    }
}

public enum SevenZipRace {
    public static func sevenZipURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/7z",
            "/opt/homebrew/bin/7zz",
            "/usr/local/bin/7z",
            "/usr/local/bin/7zz",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
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

        var rivalBytes: Int?
        var rivalTime: Double?
        var rivalName = "7-Zip (not found)"

        if let exe = sevenZipURL() {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("furl-race-\(UUID().uuidString)", isDirectory: true)
            let payloadDir = tmp.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: payloadDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            try FurlArchive.writeEntries(entries, into: payloadDir)
            let archive = tmp.appendingPathComponent("rival.7z")
            let threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
            let t1 = Date()
            let proc = Process()
            proc.executableURL = exe
            proc.arguments = ["a", "-t7z", "-mx=9", "-m0=lzma2", "-mmt=\(threads)", archive.path, "."]
            proc.currentDirectoryURL = payloadDir
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
            rivalTime = Date().timeIntervalSince(t1)
            guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: archive.path) else {
                throw FurlError.sevenZip("7-Zip failed to create an archive.")
            }
            rivalBytes = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int
            rivalName = "7-Zip ultra (LZMA2, \(threads) threads)"
        } else {
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
            furlWon: won
        )
    }
}
