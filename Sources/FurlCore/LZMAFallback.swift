import Compression
import Foundation

public enum LZMAFallback {
    /// Apple's LZMA encoder uses one thread per buffer. Payloads of at least 2 MiB
    /// are split into independent chunks and encoded together, one chunk per core.
    public static func compress(
        _ data: Data,
        shouldContinue: (() -> Bool)? = nil
    ) throws -> (data: Data, threads: Int) {
        let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let minChunk = 1 << 20
        guard data.count >= minChunk * 2, workers > 1 else {
            if let shouldContinue, !shouldContinue() { throw FurlError.cancelled }
            return (try encode(data), 1)
        }
        let byteCount = data.count
        let pieces = min(workers, byteCount / minChunk)
        let chunkSize = (byteCount + pieces - 1) / pieces
        let count = (byteCount + chunkSize - 1) / chunkSize
        let box = ChunkBox(count: count)
        let encoded: [Data] = try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw FurlError.sevenZip("LZMA fallback failed.")
            }
            DispatchQueue.concurrentPerform(iterations: count) { index in
                if let shouldContinue, !shouldContinue() {
                    box.cancel()
                    return
                }
                let start = index * chunkSize
                let n = min(chunkSize, byteCount - start)
                do {
                    let piece = try encode(base + start, n)
                    box.store(piece, at: index)
                } catch {
                    box.fail(error)
                }
            }
            if box.cancelled { throw FurlError.cancelled }
            if let error = box.failure { throw error }
            return try box.takeAll()
        }
        var out = Data()
        var total = 0
        for piece in encoded { total += piece.count }
        out.reserveCapacity(total)
        for piece in encoded { out.append(piece) }
        return (out, count)
    }

    private static func encode(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        return try data.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw FurlError.sevenZip("LZMA fallback failed.")
            }
            return try encode(src, raw.count)
        }
    }

    private static func encode(_ src: UnsafePointer<UInt8>, _ count: Int) throws -> Data {
        if count == 0 { return Data() }
        let dstCap = count + count / 3 + 4096
        var dst = Data(count: dstCap)
        let written = dst.withUnsafeMutableBytes { dstBuf -> Int in
            guard let dstPtr = dstBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                dstPtr, dstCap,
                src, count,
                nil,
                COMPRESSION_LZMA
            )
        }
        guard written > 0 else {
            throw FurlError.sevenZip("LZMA fallback produced no output.")
        }
        dst.count = written
        return dst
    }
}

private final class ChunkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Data?]
    private var error: Error?
    private var stopped = false

    init(count: Int) {
        parts = Array(repeating: nil, count: count)
    }

    func store(_ data: Data, at index: Int) {
        lock.lock()
        parts[index] = data
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        if self.error == nil { self.error = error }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func takeAll() throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        var out: [Data] = []
        out.reserveCapacity(parts.count)
        for part in parts {
            guard let part else { throw FurlError.sevenZip("LZMA fallback failed.") }
            out.append(part)
        }
        return out
    }
}
