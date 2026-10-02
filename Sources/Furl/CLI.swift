import Foundation
import FurlCore

enum CLI {
    static func runAndExitIfNeeded() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first, ["compress", "expand", "race", "--help", "-h"].contains(cmd) else {
            return
        }
        do {
            switch cmd {
            case "--help", "-h":
                print(usage)
            case "compress":
                try compress(Array(args.dropFirst()))
            case "expand":
                try expand(Array(args.dropFirst()))
            case "race":
                try race(Array(args.dropFirst()))
            default:
                break
            }
            exit(0)
        } catch {
            fputs("furl: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static let usage = """
    Furl — custom compressor

      Furl compress [-l 1-9] <input> [output.furl]
      Furl expand <archive.furl> [directory]
      Furl race [-l 1-9] <input>

    """

    private static func compress(_ args: [String]) throws {
        var level = 7
        var rest = args
        if rest.first == "-l", rest.count >= 2 {
            level = Int(rest[1]) ?? 7
            rest = Array(rest.dropFirst(2))
        }
        guard let input = rest.first else { throw FurlError.format(usage) }
        let inURL = URL(fileURLWithPath: input)
        let outURL = rest.count > 1
            ? URL(fileURLWithPath: rest[1])
            : inURL.appendingPathExtension(FurlArchive.fileExtension)
        let entries = try FileGather.entries(from: [inURL])
        var parsed: DensityReport?
        let data = try FurlArchive.pack(entries, level: level, parseReport: { parsed = $0 })
        try data.write(to: outURL, options: .atomic)
        print("\(input) -> \(outURL.path) (\(data.count) bytes)")
        if let parsed {
            print(parsed.document, terminator: "")
        }
    }

    private static func expand(_ args: [String]) throws {
        guard let input = args.first else { throw FurlError.format(usage) }
        let inURL = URL(fileURLWithPath: input)
        let dest = args.count > 1
            ? URL(fileURLWithPath: args[1])
            : inURL.deletingPathExtension()
        let entries = try FurlArchive.unpack(Data(contentsOf: inURL))
        try FurlArchive.writeEntries(entries, into: dest)
        print("expanded \(entries.count) file(s) -> \(dest.path)")
    }

    private static func race(_ args: [String]) throws {
        var level = 9
        var rest = args
        if rest.first == "-l", rest.count >= 2 {
            level = Int(rest[1]) ?? 9
            rest = Array(rest.dropFirst(2))
        }
        guard let input = rest.first else { throw FurlError.format(usage) }
        let entries = try FileGather.entries(from: [URL(fileURLWithPath: input)])
        let result = try SevenZipRace.race(entries: entries, level: level)
        print(result.document, terminator: "")
    }
}
