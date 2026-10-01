import Darwin
import Foundation
import FurlCore

var failures = 0
var passes = 0

func expect(_ cond: @autoclosure () -> Bool, _ msg: String) {
    if cond() {
        passes += 1
    } else {
        failures += 1
        fputs("FAIL \(msg)\n", stderr)
    }
}

func expectThrow(_ msg: String, containing needle: String? = nil, _ body: () throws -> Void) {
    do {
        try body()
        expect(false, "\(msg) — expected throw")
    } catch {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if let needle {
            expect(text.localizedCaseInsensitiveContains(needle), "\(msg) — message \(text) should contain \(needle)")
        } else {
            passes += 1
        }
    }
}

func roundtrip(_ name: String, _ data: Data, level: Int) {
    do {
        let packed = try FurlArchive.pack([FurlEntry(path: name, data: data)], level: level)
        let out = try FurlArchive.unpack(packed)
        expect(out.count == 1 && out[0].data == data, "\(name) level \(level) roundtrip")
        expect(FurlArchive.isArchive(packed), "\(name) magic")
    } catch {
        expect(false, "\(name) level \(level) threw \(error)")
    }
}

// MARK: - Happy path

roundtrip("empty", Data(), level: 1)
roundtrip("one", Data([0x42]), level: 7)
roundtrip("zeros", Data(repeating: 0, count: 4096), level: 1)
roundtrip("zeros-l7", Data(repeating: 0, count: 4096), level: 7)

var fox = Data()
let snip = Data("The quick brown fox jumps over the lazy dog. ".utf8)
while fox.count < 8000 { fox.append(snip) }
fox = Data(fox.prefix(8000))
roundtrip("fox-l1", fox, level: 1)
roundtrip("fox-l7", fox, level: 7)

var pseudo = Data()
for i in 0..<2000 { pseudo.append(UInt8((i * 17 + 31) & 0xFF)) }
roundtrip("pseudo", pseudo, level: 5)

do {
    let a = FurlEntry(path: "a.txt", data: Data("alpha\n".utf8))
    let b = FurlEntry(path: "sub/b.txt", data: Data("bravo\n".utf8))
    let packed = try FurlArchive.pack([a, b], level: 7)
    let out = try FurlArchive.unpack(packed)
    expect(out.map(\.path) == ["a.txt", "sub/b.txt"], "paths")
    expect(out.map(\.data) == [a.data, b.data], "payloads")
} catch {
    expect(false, "multi file \(error)")
}

do {
    let raw = try FurlCodec.compress(fox, level: 7)
    let back = try FurlCodec.decompress(raw)
    expect(back == fox, "codec fox")
    expect(raw.count < fox.count / 4, "fox shrinks a lot, got \(raw.count)")
    var extra = raw
    extra.append(0x00)
    expectThrow("codec trailing byte", containing: "corrupt") {
        _ = try FurlCodec.decompress(extra)
    }
} catch {
    expect(false, "codec \(error)")
}

do {
    var chunk = Data()
    while chunk.count < 80_000 { chunk.append(snip) }
    chunk = Data(chunk.prefix(80_000))
    var calls = 0
    let packed = try FurlCodec.compress(chunk, level: 5) { _, _ in
        calls += 1
        return true
    }
    expect(calls > 4, "progress fired during compress (\(calls))")
    let back = try FurlCodec.decompress(packed) { _, _ in true }
    expect(back == chunk, "progress roundtrip")
    var stoppedAt = 0
    expectThrow("cancel mid-compress", containing: "Cancelled") {
        _ = try FurlCodec.compress(chunk, level: 5) { _, _ in
            stoppedAt += 1
            return stoppedAt < 6
        }
    }
    expect(stoppedAt >= 6, "polled until cancel, got \(stoppedAt)")
    var unwind = 0
    expectThrow("cancel decompress", containing: "Cancelled") {
        _ = try FurlCodec.decompress(packed) { _, _ in
            unwind += 1
            return unwind < 3
        }
    }
    expect(unwind >= 3, "polled until decompress cancel, got \(unwind)")
} catch {
    expect(false, "cancel \(error)")
}

do {
    var mixed = Data(repeating: 0x41, count: 200_000)
    mixed.append(contentsOf: (0..<80_000).map { UInt8(($0 * 13) & 0xFF) })
    let packed = try FurlArchive.pack([FurlEntry(path: "mixed.bin", data: mixed)], level: 9)
    let out = try FurlArchive.unpack(packed)
    expect(out.count == 1 && out[0].data == mixed, "mixed text+binary roundtrip")
} catch {
    expect(false, "mixed \(error)")
}

do {
    /* Match distance ≥ 32 MiB used to abort encode (slot cap 24, 2^24 = 16 MiB).
       Low-entropy bytes so the block stays on the LZ path (not stored RAW). */
    let span = 32 * 1024 * 1024 + 128
    var far = Data(count: span)
    far.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt8.self)
        for i in 0..<span { p[i] = UInt8((i &* 131) & 0x3F) }
    }
    for i in 0..<64 { far[32 * 1024 * 1024 + i] = far[i] }
    let packed = try FurlArchive.pack([FurlEntry(path: "far.bin", data: far)], level: 9)
    let out = try FurlArchive.unpack(packed)
    expect(out.first?.data == far, "32MiB-distance match roundtrip")
} catch {
    expect(false, "far match \(error)")
}

do {
    var html = Data()
    let tag = Data("<div class=\"entry\"><p>The quick brown fox jumps over the lazy dog.</p></div>\n".utf8)
    while html.count < 400_000 { html.append(tag) }
    html = Data(html.prefix(400_000))
    var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
    for i in 0..<(200_000) { jpeg.append(UInt8((i &* 197 + 13) & 0xFF)) }
    var mixed = html
    mixed.append(jpeg)
    mixed.append(html)
    let packed = try FurlArchive.pack([FurlEntry(path: "page.bin", data: mixed)], level: 9)
    let out = try FurlArchive.unpack(packed)
    expect(out.count == 1 && out[0].data == mixed, "html+jpeg+html roundtrip")
    expect(packed.count < mixed.count, "html+jpeg shrinks overall, got \(packed.count)")
} catch {
    expect(false, "html+jpeg \(error)")
}

do {
    var blob = Data()
    blob.reserveCapacity(120_000)
    for i in 0..<10000 {
        blob.append(contentsOf: "PCM-HDR-\(i % 17)-".utf8)
        for k in 0..<8 { blob.append(UInt8((i &* 13 &+ k) & 0x7F)) }
    }
    let a = FurlEntry(path: "cache/AppKit-aaa.pcm", data: blob)
    let note = FurlEntry(path: "readme.txt", data: Data("hello\n".utf8))
    let b = FurlEntry(path: "out/AppKit-bbb.pcm", data: blob)
    let packed = try FurlArchive.pack([a, note, b], level: 7)
    let out = try FurlArchive.unpack(packed)
    expect(out.map(\.path) == ["cache/AppKit-aaa.pcm", "out/AppKit-bbb.pcm", "readme.txt"], "solid sort groups extension then name")
    expect(out.map(\.data) == [blob, blob, note.data], "solid sort payloads follow table")
} catch {
    expect(false, "solid sort \(error)")
}

do {
    var macho = Data([0xCF, 0xFA, 0xED, 0xFE])
    macho.append(Data(repeating: 0, count: 32))
    let script = Data("#!/bin/sh\necho hi\n".utf8)
    let packed = try FurlArchive.pack([
        FurlEntry(path: "Sigil.app/Contents/MacOS/Sigil", data: macho, mode: 0o755),
        FurlEntry(path: "build-app.sh", data: script, mode: 0o755),
        FurlEntry(path: ".build/release", data: Data(), mode: 0o755, symlinkTarget: "arm64-apple-macosx/release"),
    ], level: 7)
    let out = try FurlArchive.unpack(packed)
    expect(out.contains { $0.path.hasSuffix("MacOS/Sigil") && Int($0.mode) & 0o111 != 0 }, "stores executable mode")
    expect(out.contains { $0.path == ".build/release" && $0.symlinkTarget == "arm64-apple-macosx/release" }, "stores symlink")
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("furl-meta-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FurlArchive.writeEntries(out, into: tmp)
    let bin = tmp.appendingPathComponent("Sigil.app/Contents/MacOS/Sigil")
    let perms = try FileManager.default.attributesOfItem(atPath: bin.path)[.posixPermissions] as? NSNumber
    expect((perms?.intValue ?? 0) & 0o111 != 0, "macho is executable on disk, got \(perms?.intValue ?? -1)")
    let link = tmp.appendingPathComponent(".build/release")
    let vals = try link.resourceValues(forKeys: [.isSymbolicLinkKey])
    expect(vals.isSymbolicLink == true, "symlink restored on disk")
    let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    expect(dest == "arm64-apple-macosx/release", "symlink target \(dest)")
} catch {
    expect(false, "perms/symlink \(error)")
}

do {
    let old = Date(timeIntervalSince1970: -86_400)
    let packed = try FurlArchive.pack([
        FurlEntry(path: "old.bin", data: Data([1, 2, 3]), modified: old)
    ], level: 1)
    let out = try FurlArchive.unpack(packed)
    expect(out.first?.modified?.timeIntervalSince1970 == -86_400, "pre-1970 mtime roundtrip \(out.first?.modified?.timeIntervalSince1970 ?? 0)")

    let recent = Date(timeIntervalSince1970: 1_700_000_000)
    let packedRecent = try FurlArchive.pack([
        FurlEntry(path: "now.bin", data: Data([4]), modified: recent)
    ], level: 1)
    let outRecent = try FurlArchive.unpack(packedRecent)
    expect(outRecent.first?.modified?.timeIntervalSince1970 == 1_700_000_000, "positive mtime stays whole seconds")

    let linkTime = Date(timeIntervalSince1970: 1_600_000_000)
    let linkPacked = try FurlArchive.pack([
        FurlEntry(path: "link", data: Data(), modified: linkTime, mode: 0o755, symlinkTarget: "target")
    ], level: 1)
    let linkOut = try FurlArchive.unpack(linkPacked)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("furl-link-mtime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FurlArchive.writeEntries(linkOut, into: dir)
    let linkURL = dir.appendingPathComponent("link")
    var st = stat()
    let rc = lstat(linkURL.path, &st)
    if rc == 0 {
        expect(st.st_mtimespec.tv_sec == 1_600_000_000, "symlink mtime \(st.st_mtimespec.tv_sec)")
    } else {
        expect(false, "lstat symlink rc \(rc)")
    }
} catch {
    expect(false, "mtime \(error)")
}

expect(FurlCodec.version == "1.5.13", "codec version \(FurlCodec.version)")

do {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("furl-escape-\(UUID().uuidString)", isDirectory: true)
    let dest = base.appendingPathComponent("dest", isDirectory: true)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let payload = Data("pwned-\(UUID().uuidString)".utf8)
    let outsideFile = outside.appendingPathComponent("file.txt")
    expectThrow("archive symlink traversal", containing: "symlink") {
        try FurlArchive.writeEntries([
            FurlEntry(path: "folder/link", data: Data(), symlinkTarget: "../../outside"),
            FurlEntry(path: "folder/link/file.txt", data: payload),
        ], into: dest)
    }
    expect(!FileManager.default.fileExists(atPath: outsideFile.path), "archive link did not write outside")

    try FileManager.default.createDirectory(at: dest.appendingPathComponent("folder"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: dest.appendingPathComponent("folder/link").path,
        withDestinationPath: "../../outside"
    )
    expectThrow("planted symlink traversal", containing: "symlink") {
        try FurlArchive.writeEntries([
            FurlEntry(path: "folder/link/file.txt", data: payload),
        ], into: dest)
    }
    expect(!FileManager.default.fileExists(atPath: outsideFile.path), "planted link did not write outside")

    let planted = dest.appendingPathComponent("note.txt")
    try FileManager.default.createSymbolicLink(atPath: planted.path, withDestinationPath: "../outside/planted")
    try FurlArchive.writeEntries([
        FurlEntry(path: "note.txt", data: Data("inside".utf8)),
    ], into: dest)
    var st = stat()
    expect(lstat(planted.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG, "final symlink replaced by a file")
    let note = try Data(contentsOf: planted)
    expect(note == Data("inside".utf8), "file written at the entry path")
    expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("planted").path), "final symlink was not followed")
} catch {
    expect(false, "symlink traversal \(error)")
}

if let seven = SevenZipRace.sevenZipURL() {
    do {
        let result = try SevenZipRace.race(entries: [FurlEntry(path: "fox.txt", data: fox)], level: 7)
        expect(result.originalBytes == 8000, "race orig")
        expect(result.furlBytes > 0, "race furl size")
        expect(result.rivalBytes != nil, "7-Zip at \(seven.path) produced a size")
        if let rival = result.rivalBytes {
            expect(result.furlBytes < rival, "Furl \(result.furlBytes) should beat 7-Zip \(rival) on repeating fox")
        }
    } catch {
        expect(false, "race \(error)")
    }
} else {
    fputs("note: 7-Zip not installed, skipping race\n", stderr)
}

do {
    var wide = Data()
    while wide.count < 80_000 { wide.append(snip) }
    wide = Data(wide.prefix(80_000))
    var report: DensityReport?
    let packed = try FurlCodec.compress(wide, level: 9, parseReport: { report = $0 })
    let back = try FurlCodec.decompress(packed)
    expect(back == wide, "density 9 text roundtrip")
    expect(report != nil, "density 9 wrote a parse report")
    if let report {
        expect(report.ppmBytes == UInt64(wide.count), "long text stays on PPM, ppmBytes \(report.ppmBytes)")
        expect(report.matches == 0, "PPM does not record LZ matches")
        expect(report.document.hasPrefix("Density 9 parse\n"), "parse document title")
        expect(report.document.contains("PPM"), "parse document names PPM")
        let beside = DensityReport.fileURL(beside: URL(fileURLWithPath: "/tmp/Archive.furl"))
        expect(beside.lastPathComponent == "Archive.parse.txt", "parse sidecar \(beside.lastPathComponent)")
        fputs("note: \(report.line)\n", stderr)
    }
} catch {
    expect(false, "density report \(error)")
}

do {
    // Short lines that share a shape. The varying digits are not a special case;
    // a sample has to prefer a Burrows-Wheeler block or this stays on order-5 PPM.
    var lines = Data()
    var state: UInt64 = 0x1234_5678_9abc_def0
    while lines.count < 400_000 {
        var digits = ""
        var n = state
        state = state &* 6364136223846793005 &+ 1
        for _ in 0..<8 {
            digits.append(contentsOf: String(n % 10))
            n /= 10
        }
        lines.append(contentsOf: "          1.\(digits)e-10,\n".utf8)
    }
    let packed = try FurlCodec.compress(lines, level: 7)
    let back = try FurlCodec.decompress(packed)
    expect(back == lines, "similar lines roundtrip")
    expect(packed.count * 4 < lines.count, "similar lines stay under a quarter, \(packed.count) of \(lines.count)")
    let flagBytes = [UInt8](packed.dropFirst(36).prefix(4))
    let flags = flagBytes.count == 4
        ? UInt32(flagBytes[0]) | (UInt32(flagBytes[1]) << 8) | (UInt32(flagBytes[2]) << 16) | (UInt32(flagBytes[3]) << 24)
        : 0
    expect((flags & 0x40) != 0, "similar lines use the zero-run coder, flags \(flags)")
} catch {
    expect(false, "similar lines \(error)")
}

do {
    var unit = Data(count: 64)
    unit[0] = 0
    for i in 1..<unit.count { unit[i] = UInt8(truncatingIfNeeded: i &* 17 &+ 3) }
    var bin = Data()
    while bin.count < 80_000 { bin.append(unit) }
    bin = Data(bin.prefix(80_000))
    var report: DensityReport?
    let packed = try FurlCodec.compress(bin, level: 9, parseReport: { report = $0 })
    let back = try FurlCodec.decompress(packed)
    expect(back == bin, "density 9 binary roundtrip")
    if let report {
        expect(report.matches > 0, "repetitive binary produced matches")
        expect(report.matchBytes > report.literalBytes, "matches cover more than literals")
        expect(report.longestMatch >= 32, "longest match \(report.longestMatch)")
        expect(report.candidates > report.matches, "candidates were considered")
        expect(report.predictedBits > 0 && report.codedBits > 0, "predicted \(report.predictedBits) coded \(report.codedBits)")
        expect(report.literalBytes + report.matchBytes == report.lzBytes, "LZ bytes split into literals and matches")
        expect(report.document.contains("Matches:"), "parse document lists matches")
        expect(report.document.contains("Predicted"), "parse document lists cost")
        let lenSum = report.length2to3 + report.length4to7 + report.length8to15 + report.length16to31 + report.length32to63 + report.length64
        let distSum = report.distance256 + report.distance4K + report.distance64K + report.distance1M + report.distance16M + report.distanceFar
        expect(lenSum == report.matches, "length histogram \(lenSum) vs matches \(report.matches)")
        expect(distSum == report.matches, "distance histogram \(distSum) vs matches \(report.matches)")
        expect(report.rep0 + report.rep1 + report.rep2 + report.rep3 == report.repeatHits, "rep slots \(report.rep0 + report.rep1 + report.rep2 + report.rep3) vs hits \(report.repeatHits)")
        expect(report.shortNonRepeat <= report.length2to3 + report.length4to7, "short non-repeat fits the 2–7 buckets")
        expect(report.document.contains("Match lengths"), "parse document lists length buckets")
        expect(report.document.contains("Rejected as too expensive"), "parse document lists rejected matches")
        expect(report.document.contains("rep0"), "parse document lists repeat slots")
        fputs("note: \(report.line)\n", stderr)
        fputs("\(report.document)", stderr)
    }
} catch {
    expect(false, "density binary report \(error)")
}

do {
    var blob = Data(count: 40_000)
    var state: UInt64 = 0xC0FFEE
    blob.withUnsafeMutableBytes { buf in
        let p = buf.bindMemory(to: UInt8.self)
        for i in 0..<buf.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            p[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    let entries = [
        FurlEntry(path: "a.bin", data: blob),
        FurlEntry(path: "b.bin", data: blob)
    ]
    var report: DensityReport?
    let packed = try FurlArchive.pack(entries, level: 9, parseReport: { report = $0 })
    let back = try FurlArchive.unpack(packed)
    expect(back.count == 2 && back[0].data == blob && back[1].data == blob, "duplicate high-entropy roundtrip")
    expect(packed.count < blob.count + blob.count / 2, "second copy is matched, archive \(packed.count) vs two blobs \(blob.count * 2)")
    expect((report?.matches ?? 0) > 0, "duplicate high-entropy produced matches")
    expect((report?.rawBytes ?? UInt64.max) < UInt64(blob.count * 2), "duplicate high-entropy was not stored whole")
} catch {
    expect(false, "duplicate high-entropy \(error)")
}

do {
    var raw = Data(count: 65536)
    var state: UInt64 = 0x123456789ABCDEF
    raw.withUnsafeMutableBytes { buf in
        let p = buf.bindMemory(to: UInt8.self)
        for i in 0..<buf.count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            p[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
    }
    var report: DensityReport?
    let packed = try FurlArchive.pack([FurlEntry(path: "noise.bin", data: raw)], level: 9, parseReport: { report = $0 })
    let back = try FurlArchive.unpack(packed)
    expect(back.first?.data == raw, "high-entropy roundtrip")
    expect(report?.rawBytes == UInt64(raw.count), "high-entropy stored, rawBytes \(report?.rawBytes ?? 0)")
    expect(report?.matches == 0, "high-entropy was not parsed as LZ")
} catch {
    expect(false, "high entropy \(error)")
}

do {
    func jpegBlob(count: Int, seed: UInt64) -> Data {
        var blob = Data(count: count)
        var state = seed
        blob.withUnsafeMutableBytes { buf in
            let p = buf.bindMemory(to: UInt8.self)
            let magic: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]
            for i in 0..<min(magic.count, buf.count) { p[i] = magic[i] }
            for i in magic.count..<buf.count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                p[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return blob
    }
    let once = jpegBlob(count: 60 * 1024, seed: 0xA11CE)
    var onceReport: DensityReport?
    let oncePacked = try FurlArchive.pack([FurlEntry(path: "once.jpg", data: once)], level: 9, parseReport: { onceReport = $0 })
    let onceBack = try FurlArchive.unpack(oncePacked)
    expect(onceBack.first?.data == once, "single packed image roundtrip")
    expect(onceReport?.rawBytes == UInt64(once.count), "single packed image stored, rawBytes \(onceReport?.rawBytes ?? 0)")
    expect(onceReport?.matches == 0, "single packed image was not parsed")

    let twicePacked = try FurlArchive.pack([
        FurlEntry(path: "a.jpg", data: once),
        FurlEntry(path: "b.jpg", data: once)
    ], level: 9, parseReport: { onceReport = $0 })
    let twiceBack = try FurlArchive.unpack(twicePacked)
    expect(twiceBack.count == 2 && twiceBack[0].data == once && twiceBack[1].data == once, "duplicate packed image roundtrip")
    expect(twicePacked.count < once.count + once.count / 2, "second packed image is matched, archive \(twicePacked.count) vs two images \(once.count * 2)")
    expect((onceReport?.matches ?? 0) > 0, "duplicate packed image produced matches")
    expect((onceReport?.rawBytes ?? UInt64.max) < UInt64(once.count), "duplicate packed image was not stored whole")
} catch {
    expect(false, "packed image copy \(error)")
}

do {
    func planted(_ count: Int, seed: UInt64, mark: [UInt8]) -> Data {
        var blob = Data(count: count)
        var state = seed
        blob.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<4096 { p[i] = UInt8(i & 0x3F) }
            for i in 4096..<count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                p[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
            for (j, b) in mark.enumerated() where 4096 + j < count { p[4096 + j] = b }
        }
        return blob
    }
    func expectMatched(_ name: String, _ mark: [UInt8]) throws {
        let body = planted(128 * 1024, seed: 0x61C5, mark: mark)
        var report: DensityReport?
        let packed = try FurlArchive.pack([
            FurlEntry(path: "a.bin", data: body),
            FurlEntry(path: "b.bin", data: body)
        ], level: 9, parseReport: { report = $0 })
        let back = try FurlArchive.unpack(packed)
        expect(back.count == 2 && back[0].data == body && back[1].data == body, "\(name) roundtrip")
        expect((report?.rawBytes ?? UInt64.max) < 48 * 1024, "\(name) stayed matchable, rawBytes \(report?.rawBytes ?? 0)")
        expect(packed.count < 180 * 1024, "\(name) archive \(packed.count)")
    }
    try expectMatched("false gzip", [0x1F, 0x8B, 0x8F, 0x0B])
    try expectMatched("gzip reserved flags", [0x1F, 0x8B, 0x08, 0xE0])
    try expectMatched("false zip", [0x50, 0x4B, 0x03, 0xFF])
    try expectMatched("false jpeg", [0xFF, 0xD8, 0xFF, 0x00])

    func storedHeader(_ name: String, _ mark: [UInt8]) throws {
        var blob = Data(count: 80 * 1024)
        var state: UInt64 = 0x6A21
        let n = blob.count
        blob.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for (j, b) in mark.enumerated() { p[j] = b }
            for i in mark.count..<n {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                p[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        var report: DensityReport?
        let packed = try FurlArchive.pack([FurlEntry(path: name, data: blob)], level: 9, parseReport: { report = $0 })
        let back = try FurlArchive.unpack(packed)
        expect(back.first?.data == blob, "\(name) roundtrip")
        expect(report?.rawBytes == UInt64(blob.count), "\(name) stored, rawBytes \(report?.rawBytes ?? 0)")
    }
    try storedHeader("real.gz", [0x1F, 0x8B, 0x08, 0x00])
    try storedHeader("named.gz", [0x1F, 0x8B, 0x08, 0x08])
    try storedHeader("real.zip", [0x50, 0x4B, 0x03, 0x04])
    try storedHeader("zip-eocd.zip", [0x50, 0x4B, 0x05, 0x06])
    try storedHeader("zip-span.zip", [0x50, 0x4B, 0x07, 0x08])
} catch {
    expect(false, "header sniff \(error)")
}

do {
    func noise(_ count: Int, seed: UInt64) -> Data {
        var blob = Data(count: count)
        var state = seed
        blob.withUnsafeMutableBytes { buf in
            let p = buf.bindMemory(to: UInt8.self)
            for i in 0..<buf.count {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                p[i] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return blob
    }
    var pattern = Data()
    var unit = Data(count: 64)
    unit[0] = 0
    for i in 1..<64 { unit[i] = UInt8(i) }
    while pattern.count < 256 * 1024 { pattern.append(unit) }
    let dead = noise(256 * 1024, seed: 0xD3AD)
    var mixed = pattern
    mixed.append(dead)
    var report: DensityReport?
    let packed = try FurlArchive.pack([FurlEntry(path: "mixed.bin", data: mixed)], level: 9, parseReport: { report = $0 })
    let back = try FurlArchive.unpack(packed)
    expect(back.first?.data == mixed, "mixed pattern+noise roundtrip")
    expect((report?.matches ?? 0) > 0, "pattern half still matched")
    expect((report?.rawBytes ?? 0) >= UInt64(200 * 1024), "noise half stored, rawBytes \(report?.rawBytes ?? 0)")
    expect((report?.rawBytes ?? 0) < UInt64(mixed.count), "pattern half was not stored")
    expect(packed.count < 400 * 1024, "mixed archive \(packed.count)")

    var island = pattern
    island.append(noise(80 * 1024, seed: 0x15A1))
    island.append(pattern)
    var islandReport: DensityReport?
    let islandPacked = try FurlArchive.pack([FurlEntry(path: "island.bin", data: island)], level: 9, parseReport: { islandReport = $0 })
    let islandBack = try FurlArchive.unpack(islandPacked)
    expect(islandBack.first?.data == island, "interior noise roundtrip")
    expect((islandReport?.rawBytes ?? 0) < UInt64(48 * 1024), "interior noise stayed in the block, rawBytes \(islandReport?.rawBytes ?? 0)")
    expect((islandReport?.matches ?? 0) > 0, "pattern around the noise still matched")

    let copy = noise(256 * 1024, seed: 0xBEE5)
    let twice = try FurlArchive.pack([
        FurlEntry(path: "a.bin", data: copy),
        FurlEntry(path: "b.bin", data: copy)
    ], level: 9)
    let twiceBack = try FurlArchive.unpack(twice)
    expect(twiceBack.count == 2, "echoed noise count \(twiceBack.count)")
    expect(twiceBack.first?.data == copy, "echoed noise first copy")
    expect(twiceBack.dropFirst().first?.data == copy, "echoed noise second copy")
    expect(twice.count < copy.count + copy.count / 2, "second noise copy stayed matchable, archive \(twice.count)")
} catch {
    expect(false, "incompressible carve \(error)")
}

do {
    let emptyLZ = try LZMAFallback.compress(Data())
    expect(emptyLZ.data.isEmpty, "empty LZMA returns empty data")
    expect(emptyLZ.threads == 1, "empty LZMA is one chunk")
    let small = try LZMAFallback.compress(fox)
    expect(small.threads == 1, "small LZMA stays one chunk, got \(small.threads)")
    expect(small.data.count > 0 && small.data.count < fox.count, "small LZMA shrinks fox")
    var wide = Data()
    while wide.count < (2 << 20) + 65_536 { wide.append(snip) }
    let threaded = try LZMAFallback.compress(wide)
    let again = try LZMAFallback.compress(wide)
    expect(threaded.data.count == again.data.count, "threaded LZMA size is stable")
    expect(threaded.data.count < wide.count, "threaded LZMA shrinks")
    let cores = ProcessInfo.processInfo.activeProcessorCount
    if cores > 1 {
        expect(threaded.threads > 1, "2 MiB LZMA uses \(threaded.threads) threads on \(cores) cores")
    }
} catch {
    expect(false, "lzma fallback \(error)")
}

// MARK: - Path validation

expectThrow("reject ..", containing: "..") {
    _ = try FurlArchive.pack([FurlEntry(path: "foo/../bar.txt", data: Data([1]))])
}
expectThrow("reject .", containing: "'.' segment") {
    _ = try FurlArchive.pack([FurlEntry(path: "foo/./bar.txt", data: Data([1]))])
}
expectThrow("reject absolute", containing: "relative") {
    _ = try FurlArchive.pack([FurlEntry(path: "/etc/passwd", data: Data([1]))])
}
expectThrow("reject backslash", containing: "backslash") {
    _ = try FurlArchive.pack([FurlEntry(path: "foo\\bar.txt", data: Data([1]))])
}
expectThrow("reject empty segment", containing: "empty segment") {
    _ = try FurlArchive.pack([FurlEntry(path: "foo//bar.txt", data: Data([1]))])
}
expectThrow("reject empty path", containing: "Empty") {
    _ = try FurlArchive.pack([FurlEntry(path: "", data: Data([1]))])
}
expectThrow("reject duplicate", containing: "Duplicate") {
    let a = FurlEntry(path: "x.txt", data: Data([1]))
    let b = FurlEntry(path: "x.txt", data: Data([2]))
    _ = try FurlArchive.pack([a, b])
}
expectThrow("too many files", containing: "Too many") {
    let entries = (0...FurlArchive.maxFiles).map { FurlEntry(path: "f\($0).txt", data: Data()) }
    _ = try FurlArchive.pack(entries)
}

do {
    try FurlArchive.validatePath("ok/file.txt")
    passes += 1
} catch {
    expect(false, "valid path threw \(error)")
}

// MARK: - Hostile / truncated archives

func u16(_ v: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
func u32(_ v: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
}
func u64(_ v: UInt64) -> [UInt8] {
    u32(UInt32(truncatingIfNeeded: v)) + u32(UInt32(truncatingIfNeeded: v >> 32))
}

func handArchive(
    nfiles: UInt32,
    tableCount: UInt16,
    paths: [String],
    blobs: [Data],
    crcs: [UInt32]? = nil,
    version: UInt8 = 1,
    trailing: Data = Data()
) throws -> Data {
    let payload = blobs.reduce(into: Data()) { $0.append($1) }
    let compressed = try FurlCodec.compress(payload, level: 1)
    var table = Data(u16(tableCount))
    for (i, path) in paths.enumerated() {
        let name = Data(path.utf8)
        table.append(contentsOf: u16(UInt16(name.count)))
        table.append(name)
        let blob = i < blobs.count ? blobs[i] : Data()
        table.append(contentsOf: u64(UInt64(blob.count)))
        let crc = crcs?[i] ?? 0
        table.append(contentsOf: u32(crc))
        table.append(contentsOf: u64(0))
    }
    var out = Data("FURL".utf8)
    out.append(version)
    out.append(1)
    out.append(contentsOf: u32(nfiles))
    out.append(contentsOf: u32(0))
    out.append(table)
    out.append(contentsOf: u64(UInt64(compressed.count)))
    out.append(compressed)
    out.append(trailing)
    return out
}

expectThrow("truncated header") {
    _ = try FurlArchive.unpack(Data("FURL".utf8))
}

do {
    let packed = try FurlArchive.pack([FurlEntry(path: "a.txt", data: Data("hello".utf8))])
    expectThrow("truncated body") {
        _ = try FurlArchive.unpack(packed.dropLast(8))
    }
    expectThrow("truncated mid-table") {
        _ = try FurlArchive.unpack(packed.prefix(20))
    }
} catch {
    expect(false, "setup truncated \(error)")
}

expectThrow("bad version", containing: "version") {
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 1, tableCount: 1, paths: ["a.txt"], blobs: [Data([1])], version: 99
    ))
}

do {
    var macho = Data([0xCF, 0xFA, 0xED, 0xFE])
    macho.append(Data(repeating: 0, count: 16))
    let packed = try handArchive(
        nfiles: 1,
        tableCount: 1,
        paths: ["App.app/Contents/MacOS/App"],
        blobs: [macho],
        crcs: [CRC32.hash(macho)]
    )
    let out = try FurlArchive.unpack(packed)
    expect(out.first?.mode == 0o755, "v1 macho infers executable mode")
} catch {
    expect(false, "v1 infer \(error)")
}

expectThrow("file count vs table", containing: "table") {
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 2, tableCount: 1, paths: ["a.txt"], blobs: [Data([1])]
    ))
}

expectThrow("huge file count", containing: "file count") {
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 1_000_000, tableCount: 1, paths: ["a.txt"], blobs: [Data([1])]
    ))
}

expectThrow("zero files", containing: "file count") {
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 0, tableCount: 0, paths: [], blobs: []
    ))
}

expectThrow("path traversal unpack", containing: "..") {
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 1, tableCount: 1, paths: ["foo/../secret.txt"], blobs: [Data([1])]
    ))
}

expectThrow("absolute path unpack", containing: "relative") {
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 1, tableCount: 1, paths: ["/etc/passwd"], blobs: [Data([1])]
    ))
}

expectThrow("duplicate paths unpack", containing: "Duplicate") {
    let blob = Data([9])
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 2, tableCount: 2,
        paths: ["same.txt", "same.txt"],
        blobs: [blob, blob]
    ))
}

expectThrow("bad file CRC", containing: "Checksum") {
    let blob = Data("payload".utf8)
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 1, tableCount: 1, paths: ["a.txt"], blobs: [blob], crcs: [0xDEADBEEF]
    ))
}

do {
    var packed = try FurlArchive.pack([FurlEntry(path: "a.txt", data: Data("hello".utf8))])
    let idx = packed.count / 2
    packed[idx] ^= 0xFF
    expectThrow("corrupt stream") {
        _ = try FurlArchive.unpack(packed)
    }
} catch {
    expect(false, "setup corrupt stream \(error)")
}

expectThrow("trailing junk", containing: "trailing") {
    _ = try FurlArchive.unpack(try handArchive(
        nfiles: 1, tableCount: 1, paths: ["a.txt"], blobs: [Data([1])], trailing: Data([0x00])
    ))
}

do {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("furl-dest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let dest = try FurlArchive.destination(in: folder, forRelative: "ok/file.txt")
    expect(dest.path.hasPrefix(folder.path + "/"), "destination stays inside")
} catch {
    expect(false, "destination \(error)")
}

// MARK: - Loose files stay loose

do {
    let fm = FileManager.default
    let parent = fm.temporaryDirectory.appendingPathComponent("furl-loose-\(UUID().uuidString)", isDirectory: true)
    let other = fm.temporaryDirectory.appendingPathComponent("furl-loose-b-\(UUID().uuidString)", isDirectory: true)
    let sub = parent.appendingPathComponent("Sources", isDirectory: true)
    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try fm.createDirectory(at: other, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: parent)
        try? fm.removeItem(at: other)
    }
    try Data("readme".utf8).write(to: parent.appendingPathComponent("README.md"))
    try Data("pkg".utf8).write(to: parent.appendingPathComponent("Package.swift"))
    try Data("src".utf8).write(to: sub.appendingPathComponent("main.swift"))
    try Data("other".utf8).write(to: other.appendingPathComponent("README.md"))
    let entries = try FileGather.entries(from: [
        parent.appendingPathComponent("README.md"),
        parent.appendingPathComponent("Package.swift"),
        sub,
        other.appendingPathComponent("README.md"),
    ])
    let paths = entries.map(\.path).sorted()
    expect(paths == ["Package.swift", "README-2.md", "README.md", "Sources/main.swift"], "loose files are not wrapped, got \(paths)")
    let alone = try FileGather.entries(from: [parent.appendingPathComponent("README.md")])
    expect(alone.map(\.path) == ["README.md"], "one loose file stays a file, got \(alone.map(\.path))")
} catch {
    expect(false, "loose files \(error)")
}

do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("furl-same-name-\(UUID().uuidString)", isDirectory: true)
    let a = root.appendingPathComponent("Assets", isDirectory: true)
    let b = root.appendingPathComponent("Other", isDirectory: true)
    try fm.createDirectory(at: a, withIntermediateDirectories: true)
    try fm.createDirectory(at: b, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data("a".utf8).write(to: a.appendingPathComponent("AppIcon.icns"))
    try Data("b".utf8).write(to: b.appendingPathComponent("AppIcon.icns"))
    let entries = try FileGather.entries(from: [root])
    let paths = entries.map(\.path).sorted()
    expect(paths.count == 2 && Set(paths).count == 2, "same names stay distinct, got \(paths)")
    expect(paths.contains { $0.hasSuffix("Assets/AppIcon.icns") }, "assets icon \(paths)")
    expect(paths.contains { $0.hasSuffix("Other/AppIcon.icns") }, "other icon \(paths)")
} catch {
    expect(false, "same-name paths \(error)")
}

// MARK: - Apple metadata skips

do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("furl-skip-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try Data("keep".utf8).write(to: root.appendingPathComponent("keep.txt"))
    try Data("ds".utf8).write(to: root.appendingPathComponent(".DS_Store"))
    try Data("ad".utf8).write(to: root.appendingPathComponent("._keep.txt"))
    try Data("git".utf8).write(to: root.appendingPathComponent(".gitignore"))
    let mac = root.appendingPathComponent("__MACOSX")
    try fm.createDirectory(at: mac, withIntermediateDirectories: true)
    try Data("junk".utf8).write(to: mac.appendingPathComponent("._keep.txt"))

    let keepURL = root.appendingPathComponent("keep.txt")
    let rsrc = URL(fileURLWithPath: keepURL.path + "/..namedfork/rsrc")
    try? Data("FORK".utf8).write(to: rsrc)

    expect(FileGather.isAppleDoubleName("._Icon"), "appledouble name")
    expect(FileGather.shouldSkip(root.appendingPathComponent(".DS_Store")), "skip DS_Store")
    expect(FileGather.shouldSkip(root.appendingPathComponent("._keep.txt")), "skip ._ file")
    expect(FileGather.shouldSkip(mac), "skip __MACOSX dir")
    expect(FileGather.shouldSkip(URL(fileURLWithPath: "/tmp/doc.txt/..namedfork/rsrc")), "skip namedfork/rsrc")
    expect(!FileGather.shouldSkip(root.appendingPathComponent(".gitignore")), "keep .gitignore")

    let entries = try FileGather.entries(from: [root])
    let tails = Set(entries.map { $0.path.split(separator: "/").map(String.init).last ?? $0.path })
    expect(tails.contains("keep.txt"), "kept keep.txt")
    expect(tails.contains(".gitignore"), "kept .gitignore")
    expect(!tails.contains(".DS_Store"), "no .DS_Store in archive")
    expect(!tails.contains("._keep.txt"), "no AppleDouble in archive")
    expect(entries.allSatisfy { !$0.path.split(separator: "/").contains { $0 == "__MACOSX" } }, "no __MACOSX path")
    if let keep = entries.first(where: { $0.path.split(separator: "/").last == "keep.txt" }) {
        expect(keep.data == Data("keep".utf8), "data fork only, not resource fork")
    }

    let included = try FileGather.entries(
        from: [root],
        options: FileGather.Options(
            skipAppleDouble: false,
            skipMacOSXFolder: false,
            skipDSStore: false,
            skipResourceFork: false
        )
    )
    expect(included.count > entries.count, "turning skips off includes Apple metadata")

    expectThrow("only AppleDouble") {
        _ = try FileGather.entries(from: [root.appendingPathComponent("._keep.txt")])
    }
} catch {
    expect(false, "apple skip \(error)")
}

print(failures == 0 ? "all passed (\(passes))" : "\(failures) FAILED, \(passes) passed")
exit(failures == 0 ? 0 : 1)
