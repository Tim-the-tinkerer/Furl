import Quartz
import SwiftUI

@main
struct FurlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        CLI.runAndExitIfNeeded()
        if let panel = QLPreviewPanel.shared() {
            panel.dataSource = FurlQuickLook.shared
            panel.delegate = FurlQuickLook.shared
        }
    }

    var body: some Scene {
        WindowGroup("Furl", id: "main") {
            ContentView()
                .environmentObject(model)
                .tint(Theme.accent)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onAppear { appDelegate.attach(model: model) }
                .onOpenURL { url in
                    model.add([url])
                    appDelegate.absorbExtraWindows()
                }
        }
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 720, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.open() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Furl") { model.furl() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canFurl)
                Button("Unfurl") { model.unfurl() }
                    .disabled(!model.canUnfurl)
                Button("Browse") { model.browseLatestArchive() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(!model.canBrowse)
                Button("Race 7-Zip") { model.race() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!model.canRace)
                Divider()
                Button("Show in Finder") { model.revealLast() }
                    .disabled(model.lastOutput == nil)
            }
            CommandGroup(replacing: .help) {
                Button("Furl Help") { showHelp() }
            }
            SettingsCommands(model: model)
        }
    }

    private func showHelp() {
        let a = NSAlert()
        a.messageText = "How Furl works"
        a.informativeText = """
        Furl is a custom lossless compressor: LZ77 matching plus a context-mixing arithmetic coder. It is not a wrapper around 7-Zip.

        1. Drop files or folders
        2. Choose density 1 (fast) through 9 (smallest)
        3. Furl writes a solid .furl archive
        4. Unfurl restores the original files
        5. Race 7-Zip runs 7-Zip ultra on the same payload and compares sizes

        Open a single .furl, or double-click one in the list, to browse it. The list is the file table: folders, sizes, and dates, without unpacking the solid stream. Return opens a file or a folder. Space previews a file. Extract writes the selection, and Extract All writes the archive. The solid stream is read only when you preview or extract.

        Apple metadata is skipped by default: AppleDouble (._*), __MACOSX folders, .DS_Store, and resource forks (data fork only). Turn each one on or off from the Settings menu. Hidden files like .gitignore are kept.

        Long text uses order-5 PPM. A long run of short, similar lines is tried as a Burrows-Wheeler block of at most 1 MB. Move-to-front zeros in that block are run-coded, and the block is kept only when a sample is clearly smaller than that model. Already-compressed media (JPEG, PNG, zip, and the other packed types) is stored once its magic is recognized, unless that run contains a copy of 256 bytes or more. Everything else uses LZ77. A match is kept when it costs fewer bits than literals, and the one-byte lazy choice uses the same prices. At density 9, a stretch of short matches shortens the hash-chain search, and a long match the short chain cannot see restores it. A large block samples those strategies and backs off one when the samples agree it costs more. A stretch at the start or end of an LZ block that is already near 8 bits per byte, and that has no copy in the rest of the block, is stored instead of parsed. The same stretch in the middle of the block stays there. Executables with enough call sites get an E8 filter. Numeric runs may get a 16-bit or 32-bit delta. Density 9 can write a parse report beside the archive, named like Archive.parse.txt: match lengths, distances, repeat slots, rejected short matches, and predicted cost against the arithmetic coder. Turn that file on or off from the Settings menu. It is on by default.

        Furl typically beats 7-Zip on highly redundant data (repeated JSON, generated reports, logs with a repeating shape). 7-Zip’s LZMA2 can still win on some unique text and binaries. Already-compressed media (JPEG, MP4, zip) will not shrink much with either.

        CLI (same binary):
          Furl compress [-l 9] input output.furl
          Furl expand archive.furl dest
          Furl race input
        """
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

private struct SettingsCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("Settings") {
            Section("Skip when gathering") {
                Toggle("AppleDouble (._*)", isOn: $model.skipAppleDouble)
                    .help("Sidecars created when Mac files touch non-Apple volumes or zip tools")
                Toggle("__MACOSX folders", isOn: $model.skipMacOSXFolder)
                    .help("Archive metadata folders, common after unzipping")
                Toggle(".DS_Store", isOn: $model.skipDSStore)
                    .help("Finder folder metadata")
                Toggle("Resource forks", isOn: $model.skipResourceFork)
                    .help("com.apple.ResourceFork and ..namedfork/rsrc. The data fork is still stored")
            }
            .disabled(model.isWorking)
            Section("Parse report") {
                Toggle("Write beside the archive", isOn: $model.writeParseReport)
                    .help("At density 9, save Name.parse.txt next to the .furl file")
            }
            .disabled(model.isWorking)
        }
    }
}
