import CFurl
import Foundation

public enum FurlError: Error, LocalizedError {
    case codec(Int32, String)
    case format(String)
    case cancelled
    case sevenZip(String)

    public var errorDescription: String? {
        switch self {
        case .codec(let code, let message):
            return "Furl error \(code): \(message)"
        case .format(let message):
            return message
        case .cancelled:
            return "Cancelled"
        case .sevenZip(let message):
            return message
        }
    }
}

public enum FurlCodec {
    public static let version = String(cString: furl_version())

    /// `progress` receives bytes finished and the total. Return false to stop.
    /// A call with `total == 0` only asks whether to continue; ignore it for the bar.
    public static func compress(
        _ data: Data,
        level: Int = 7,
        progress: ((UInt64, UInt64) -> Bool)? = nil,
        fileEnds: [UInt64]? = nil,
        parseReport: ((DensityReport) -> Void)? = nil
    ) throws -> Data {
        let (bytes, report) = try transcode(data, level: level, progress: progress, compress: true, fileEnds: fileEnds, wantReport: parseReport != nil)
        if let report { parseReport?(report) }
        return bytes
    }

    public static func decompress(
        _ data: Data,
        progress: ((UInt64, UInt64) -> Bool)? = nil
    ) throws -> Data {
        try transcode(data, level: 0, progress: progress, compress: false, fileEnds: nil, wantReport: false).0
    }

    private static func transcode(
        _ data: Data,
        level: Int,
        progress: ((UInt64, UInt64) -> Bool)?,
        compress: Bool,
        fileEnds: [UInt64]?,
        wantReport: Bool
    ) throws -> (Data, DensityReport?) {
        final class Box {
            let fn: (UInt64, UInt64) -> Bool
            init(_ fn: @escaping (UInt64, UInt64) -> Bool) { self.fn = fn }
        }

        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        var box: Box?
        var stats = FurlParseStats()
        let clamped = Int32(max(0, min(9, level)))
        var opt = FurlOptions(level: clamped, progress: nil, user: nil, file_ends: nil, nfiles: 0, stats: nil)
        if let progress {
            let held = Box(progress)
            box = held
            opt.user = Unmanaged.passUnretained(held).toOpaque()
            opt.progress = { user, done, total in
                guard let user else { return 1 }
                let held = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
                return held.fn(done, total) ? 1 : 0
            }
        }

        let ends = fileEnds ?? []
        let collect = compress && wantReport && clamped >= 9
        let rc: Int32 = withUnsafeMutablePointer(to: &stats) { statsPtr in
            if collect { opt.stats = statsPtr }
            return ends.withUnsafeBufferPointer { endBuf in
                if compress, !ends.isEmpty {
                    opt.file_ends = endBuf.baseAddress
                    opt.nfiles = UInt32(endBuf.count)
                }
                return data.withUnsafeBytes { buf in
                    let src = buf.bindMemory(to: UInt8.self).baseAddress
                    if compress {
                        return furl_compress(src, buf.count, &out, &outLen, &opt)
                    }
                    return furl_decompress(src, buf.count, &out, &outLen, &opt)
                }
            }
        }
        _ = box
        defer { furl_free(out) }
        let report = collect && rc == FURL_OK ? DensityReport(stats) : nil

        if rc == FURL_ERR_CANCEL { throw FurlError.cancelled }
        if rc == FURL_OK, outLen == 0 {
            return (Data(), report)
        }
        guard rc == FURL_OK, let out else {
            if rc == FURL_ERR_NOMEM {
                throw FurlError.format("Not enough memory. Try a smaller folder or a lower density.")
            }
            if compress {
                throw FurlError.format("Could not encode this data. Try a lower density.")
            }
            throw FurlError.codec(rc, String(cString: furl_error(rc)))
        }
        return (Data(bytes: out, count: outLen), report)
    }
}
