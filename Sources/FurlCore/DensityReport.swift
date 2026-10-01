import CFurl
import Foundation

/// What density 9 did with the input: which model ran, and how the LZ parser spent its bytes.
public struct DensityReport: Sendable, Equatable {
    public var literals: UInt64
    public var matches: UInt64
    public var literalBytes: UInt64
    public var matchBytes: UInt64
    public var longestMatch: UInt64
    public var repeatHits: UInt64
    public var candidates: UInt64
    public var predictedBits: Double
    public var codedBits: UInt64
    public var rawBytes: UInt64
    public var ppmBytes: UInt64
    public var lzBytes: UInt64
    public var longMatchBytes: UInt64
    public var e8Blocks: UInt32
    public var deltaBlocks: UInt32
    public var length2to3: UInt64
    public var length4to7: UInt64
    public var length8to15: UInt64
    public var length16to31: UInt64
    public var length32to63: UInt64
    public var length64: UInt64
    public var distance256: UInt64
    public var distance4K: UInt64
    public var distance64K: UInt64
    public var distance1M: UInt64
    public var distance16M: UInt64
    public var distanceFar: UInt64
    public var rep0: UInt64
    public var rep1: UInt64
    public var rep2: UInt64
    public var rep3: UInt64
    public var shortNonRepeat: UInt64
    public var shortNonRepeatBytes: UInt64
    public var rejectedMatches: UInt64
    public var rejectedBytes: UInt64

    init(_ s: FurlParseStats) {
        literals = s.literals
        matches = s.matches
        literalBytes = s.literal_bytes
        matchBytes = s.match_bytes
        longestMatch = s.longest_match
        repeatHits = s.rep_hits
        candidates = s.candidates
        predictedBits = s.predicted_bits
        codedBits = s.coded_bits
        rawBytes = s.raw_bytes
        ppmBytes = s.ppm_bytes
        lzBytes = s.lz_bytes
        longMatchBytes = s.long_bytes
        e8Blocks = s.e8_blocks
        deltaBlocks = s.delta_blocks
        length2to3 = s.len_2_3
        length4to7 = s.len_4_7
        length8to15 = s.len_8_15
        length16to31 = s.len_16_31
        length32to63 = s.len_32_63
        length64 = s.len_64
        distance256 = s.dist_256
        distance4K = s.dist_4k
        distance64K = s.dist_64k
        distance1M = s.dist_1m
        distance16M = s.dist_16m
        distanceFar = s.dist_far
        rep0 = s.rep0
        rep1 = s.rep1
        rep2 = s.rep2
        rep3 = s.rep3
        shortNonRepeat = s.short_nonrep
        shortNonRepeatBytes = s.short_nonrep_bytes
        rejectedMatches = s.rejected_matches
        rejectedBytes = s.rejected_bytes
    }

    public var averageMatch: Double {
        matches == 0 ? 0 : Double(matchBytes) / Double(matches)
    }

    public var repeatShare: Double {
        matches == 0 ? 0 : Double(repeatHits) / Double(matches)
    }

    /// Factual reading of the counters. Empty when the LZ parse does not lean either way.
    public var parseNote: String? {
        guard lzBytes > 0, matches > 0 else { return nil }
        let covered = Double(matchBytes) / Double(lzBytes)
        if longestMatch >= 64 && averageMatch < 12 && covered < 0.55 {
            return "Long matches show up, and most LZ bytes are still literals or short matches."
        }
        if covered > 0.85 && averageMatch >= 24 {
            return "Almost all LZ bytes are covered by long matches."
        }
        let gap = predictedBits > 0 ? Double(codedBits) / predictedBits : 1
        if codedBits > 0 && gap > 1.15 {
            return "The arithmetic coder spent more bits than the token probabilities predicted."
        }
        return nil
    }

    public var routeLine: String {
        var parts: [String] = []
        if lzBytes > 0 { parts.append("LZ \(Self.qty(lzBytes))") }
        if longMatchBytes > 0 { parts.append("long-match \(Self.qty(longMatchBytes))") }
        if ppmBytes > 0 { parts.append("PPM \(Self.qty(ppmBytes))") }
        if rawBytes > 0 { parts.append("stored \(Self.qty(rawBytes))") }
        if e8Blocks > 0 { parts.append("executable filter × \(e8Blocks)") }
        if deltaBlocks > 0 { parts.append("delta × \(deltaBlocks)") }
        return parts.isEmpty ? "Empty." : parts.joined(separator: " · ")
    }

    public var costLine: String {
        guard codedBits > 0 else { return "No LZ arithmetic stream." }
        return "Predicted \(Self.bits(predictedBits)) · coded \(Self.bits(Double(codedBits)))"
    }

    private static func bits(_ n: Double) -> String {
        if n < 8_000 { return String(format: "%.0f bits", n) }
        if n < 8_000_000 { return String(format: "%.1f Kb", n / 1_000) }
        return String(format: "%.2f Mb", n / 1_000_000)
    }

    public var line: String {
        let avg = String(format: "%.1f", averageMatch)
        let reps = String(format: "%.0f%%", repeatShare * 100)
        return "\(routeLine). \(Self.count(literals)) literals, \(Self.count(matches)) matches, avg \(avg), longest \(longestMatch), repeat distances \(reps). \(costLine)"
    }

    /// Plain-text form of the density 9 report. Not stored inside the archive.
    public var document: String {
        var lines = [
            "Density 9 parse",
            routeLine,
            "",
            "Literals: \(Self.count(literals)) (\(Self.qty(literalBytes)))",
            "Matches: \(Self.count(matches)) (avg \(String(format: "%.1f", averageMatch)))",
            "Longest match: \(longestMatch) bytes",
            "Repeat distances: \(String(format: "%.0f%%", repeatShare * 100)) of matches",
            "Match bytes: \(Self.qty(matchBytes)) (\(share(matchBytes, of: lzBytes)))",
            "Literal bytes: \(Self.qty(literalBytes)) (\(share(literalBytes, of: lzBytes)))",
            "Candidates: \(Self.count(candidates))",
            costLine
        ]
        if lzBytes > 0 {
            lines.append("")
            lines.append(contentsOf: histogramLines)
        }
        if let parseNote {
            lines.append(parseNote)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private var histogramLines: [String] {
        let n = matches
        return [
            "Match lengths",
            hist("2–3", length2to3, of: n),
            hist("4–7", length4to7, of: n),
            hist("8–15", length8to15, of: n),
            hist("16–31", length16to31, of: n),
            hist("32–63", length32to63, of: n),
            hist("64+", length64, of: n),
            "  Short non-repeat (2–7): \(Self.count(shortNonRepeat)) matches, \(Self.qty(shortNonRepeatBytes))",
            "",
            "Distances",
            hist("<=256 B", distance256, of: n),
            hist("<=4 KiB", distance4K, of: n),
            hist("<=64 KiB", distance64K, of: n),
            hist("<=1 MiB", distance1M, of: n),
            hist("<=16 MiB", distance16M, of: n),
            hist(">16 MiB", distanceFar, of: n),
            "",
            "Repeat matches",
            hist("rep0", rep0, of: n),
            hist("rep1", rep1, of: n),
            hist("rep2", rep2, of: n),
            hist("rep3", rep3, of: n),
            "",
            "Rejected as too expensive",
            "  matches: \(Self.count(rejectedMatches))",
            "  bytes: \(Self.qty(rejectedBytes))"
        ]
    }

    private func hist(_ label: String, _ part: UInt64, of whole: UInt64) -> String {
        let pct = whole == 0 ? 0.0 : Double(part) / Double(whole) * 100
        return String(format: "  %@: %.0f%% (%@)", label, pct, Self.count(part) as NSString)
    }

    /// `Archive.furl` → `Archive.parse.txt` in the same folder.
    public static func fileURL(beside archive: URL) -> URL {
        archive.deletingPathExtension().appendingPathExtension("parse.txt")
    }

    private func share(_ part: UInt64, of whole: UInt64) -> String {
        guard whole > 0 else { return "—" }
        return String(format: "%.0f%% of LZ", Double(part) / Double(whole) * 100)
    }

    public static func qty(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    public static func count(_ n: UInt64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}
