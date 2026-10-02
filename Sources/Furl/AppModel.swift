import AppKit
import Combine
import Foundation
import FurlCore
import os
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// Shared by the UI and the codec thread. `total == 0` is a cancel probe and does not move the bar.
private final class RunControl: @unchecked Sendable {
    private struct State {
        var stopped = false
        var shown = 0.0
        var lastPublish = 0.0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func stop() {
        lock.withLock { $0.stopped = true }
    }

    var isStopped: Bool {
        lock.withLock { $0.stopped }
    }

    func report(done: UInt64, total: UInt64) -> (stop: Bool, fraction: Double?) {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock { state in
            if state.stopped { return (true, nil) }
            guard total > 0 else { return (false, nil) }
            let frac = min(1, Double(done) / Double(total))
            if frac <= state.shown { return (false, nil) }
            if now - state.lastPublish < 0.05 && frac < 1 {
                return (false, nil)
            }
            state.shown = frac
            state.lastPublish = now
            return (false, frac)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let isDirectory: Bool
        let isArchive: Bool
        var bytes: Int

        var name: String { url.lastPathComponent }

        var sizeLabel: String {
            let n = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            if isDirectory { return "Folder · \(n)" }
            if isArchive { return "Furl archive · \(n)" }
            return n
        }
    }

    @Published var items: [Item] = []
    @Published var level: Double = 7
    @Published var skipAppleDouble: Bool {
        didSet {
            defaults.set(skipAppleDouble, forKey: "skipAppleDouble")
            refreshSizes()
        }
    }
    @Published var skipMacOSXFolder: Bool {
        didSet {
            defaults.set(skipMacOSXFolder, forKey: "skipMacOSXFolder")
            refreshSizes()
        }
    }
    @Published var skipDSStore: Bool {
        didSet {
            defaults.set(skipDSStore, forKey: "skipDSStore")
            refreshSizes()
        }
    }
    @Published var skipResourceFork: Bool {
        didSet {
            defaults.set(skipResourceFork, forKey: "skipResourceFork")
            refreshSizes()
        }
    }
    @Published var writeParseReport: Bool { didSet { defaults.set(writeParseReport, forKey: "writeParseReport") } }
    @Published var writeRaceReport: Bool { didSet { defaults.set(writeRaceReport, forKey: "writeRaceReport") } }
    @Published var isWorking = false
    @Published var isStopping = false
    @Published var progress: Double = 0
    private var runControl: RunControl?
    private enum Activity { case furl, unfurl, race, browse, solid }
    private var activity: Activity?
    private var browseToken = 0
    private var solidGeneration = 0
    private var solidLoad: Task<[FurlEntry], Error>?
    static let idleStatus = "Drop files to compress them with Furl."

    private let defaults = UserDefaults.standard

    var gatherOptions: FileGather.Options {
        FileGather.Options(
            skipAppleDouble: skipAppleDouble,
            skipMacOSXFolder: skipMacOSXFolder,
            skipDSStore: skipDSStore,
            skipResourceFork: skipResourceFork
        )
    }

    init() {
        let d = UserDefaults.standard
        func flag(_ key: String) -> Bool {
            d.object(forKey: key) as? Bool ?? true
        }
        skipAppleDouble = flag("skipAppleDouble")
        skipMacOSXFolder = flag("skipMacOSXFolder")
        skipDSStore = flag("skipDSStore")
        skipResourceFork = flag("skipResourceFork")
        writeParseReport = flag("writeParseReport")
        writeRaceReport = flag("writeRaceReport")
    }

    @Published var status = AppModel.idleStatus
    @Published var alertMessage: String?
    @Published var lastOutput: URL?
    @Published var lastRace: RaceResult?
    @Published var lastReportURL: URL?
    @Published var lastRaceReportURL: URL?
    @Published var listing: FurlListing?
    @Published var browserURL: URL?
    @Published var browserPath = ""
    @Published var browserSelection = Set<String>()
    private var materialized: [FurlEntry]?
    private var previewRoot: URL?

    var showsBrowser: Bool { listing != nil || activity == .browse }

    var browserRows: [FurlBrowserRow] {
        guard let listing else { return [] }
        return FurlBrowserIndex.children(of: browserPath, in: listing.files)
    }

    var canBrowse: Bool {
        !isWorking && items.contains { $0.isArchive && !$0.isDirectory }
    }

    var canFurl: Bool { !items.isEmpty && !isWorking && items.contains(where: { !$0.isArchive }) }
    var canUnfurl: Bool { !items.isEmpty && !isWorking && items.contains(where: { $0.isArchive }) }
    var canRace: Bool { canFurl }

    func add(_ urls: [URL]) {
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey])
            let isDir = values?.isDirectory == true
            let size: Int
            if isDir {
                size = (try? directorySize(url)) ?? 0
            } else {
                size = values?.fileSize ?? 0
            }
            if FileGather.shouldSkip(url, options: gatherOptions) { continue }
            if items.contains(where: { $0.url == url }) { continue }
            let archive = !isDir && FurlArchive.isArchive(url: url)
            items.append(Item(
                url: url,
                isDirectory: isDir,
                isArchive: archive,
                bytes: size
            ))
        }
        let canOpenArchive = !isWorking || activity == .browse
        if urls.count == 1, let url = urls.first, canOpenArchive, !FileGather.shouldSkip(url, options: gatherOptions) {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isDir && FurlArchive.isArchive(url: url) {
                browse(url)
                return
            }
        }
        if isWorking { return }
        if listing != nil {
            closeBrowser()
        }
        status = "\(items.count) item(s) ready."
    }

    func clear() {
        closeBrowser()
        items.removeAll()
        lastRace = nil
        lastReportURL = nil
        lastRaceReportURL = nil
        status = AppModel.idleStatus
    }

    func browseLatestArchive() {
        guard let url = items.last(where: { $0.isArchive && !$0.isDirectory })?.url else { return }
        browse(url)
    }

    func browse(_ url: URL) {
        if isWorking, activity != .browse { return }
        if activity == .browse {
            runControl?.stop()
        }
        browseToken += 1
        let token = browseToken
        let control = beginRun("Reading the file table…", .browse)
        listing = nil
        browserURL = nil
        browserPath = ""
        browserSelection = []
        discardSolidCache()
        Task {
            let listed: FurlListing
            do {
                listed = try await Task.detached {
                    if control.isStopped { throw FurlError.cancelled }
                    let data = try Data(contentsOf: url)
                    if control.isStopped { throw FurlError.cancelled }
                    return try FurlArchive.catalog(data)
                }.value
            } catch {
                guard self.browseToken == token else { return }
                self.noteFailure(error, failed: "Could not browse that archive.")
                self.endRun()
                return
            }
            guard self.browseToken == token else { return }
            if control.isStopped {
                self.noteFailure(FurlError.cancelled, failed: "Could not browse that archive.")
                self.endRun()
                return
            }
            self.discardSolidCache()
            self.listing = listed
            self.browserURL = url
            self.browserPath = ""
            self.browserSelection = []
            let solid = bytes(Int(listed.compressedBytes))
            let raw = bytes(Int(listed.uncompressedBytes))
            self.status = "\(url.lastPathComponent) · \(listed.files.count) item(s) · \(raw) unpacked, \(solid) solid. The list does not unpack the archive."
            self.endRun()
        }
    }

    func closeBrowser() {
        browseToken += 1
        if activity == .browse || activity == .solid {
            runControl?.stop()
            endRun()
        }
        listing = nil
        browserURL = nil
        browserPath = ""
        browserSelection = []
        discardSolidCache()
    }

    private func discardSolidCache() {
        solidGeneration += 1
        materialized = nil
        solidLoad = nil
        if let previewRoot {
            try? FileManager.default.removeItem(at: previewRoot)
            self.previewRoot = nil
        }
        FurlQuickLook.shared.url = nil
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func browserNavigate(to path: String) {
        browserPath = path
        browserSelection = []
    }

    func browserOpen(_ row: FurlBrowserRow) {
        if row.isDirectory {
            browserNavigate(to: row.path)
            return
        }
        if row.isSymlink {
            let target = listing?.files.first { $0.path == row.path }?.symlinkTarget ?? ""
            alertMessage = "\(row.name) is a symlink to \(target)."
            return
        }
        Task { await revealBrowsed(row, quickLook: false) }
    }

    func browserQuickLook(_ row: FurlBrowserRow) {
        guard !row.isDirectory else {
            browserNavigate(to: row.path)
            return
        }
        if row.isSymlink {
            browserOpen(row)
            return
        }
        Task { await revealBrowsed(row, quickLook: true) }
    }

    func browserOpenSelection() {
        guard let row = selectedBrowserRows().first else {
            alertMessage = "Select a file or folder."
            return
        }
        browserOpen(row)
    }

    func browserQuickLookSelection() {
        guard let row = selectedBrowserRows().first(where: { !$0.isDirectory }) ?? selectedBrowserRows().first else {
            alertMessage = "Select a file to preview."
            return
        }
        browserQuickLook(row)
    }

    func browserExtract(_ row: FurlBrowserRow) {
        guard let dest = chooseDirectory(prompt: "Extract") else { return }
        let paths = expandedPaths([row])
        Task { await extractBrowsed(paths: paths, to: dest, label: row.name) }
    }

    func browserExtractSelection() {
        let rows = selectedBrowserRows()
        guard !rows.isEmpty else {
            alertMessage = "Select one or more items to extract."
            return
        }
        guard let dest = chooseDirectory(prompt: "Extract") else { return }
        let paths = expandedPaths(rows)
        Task { await extractBrowsed(paths: paths, to: dest, label: "\(paths.count) item(s)") }
    }

    func browserExtractAll() {
        guard listing != nil else { return }
        guard let dest = chooseDirectory(prompt: "Extract") else { return }
        Task { await extractBrowsed(paths: nil, to: dest, label: "every file") }
    }

    private func selectedBrowserRows() -> [FurlBrowserRow] {
        browserRows.filter { browserSelection.contains($0.path) }
    }

    private func expandedPaths(_ rows: [FurlBrowserRow]) -> [String] {
        guard let listing else { return [] }
        var paths: [String] = []
        for row in rows {
            if row.isDirectory {
                paths.append(contentsOf: listing.files.map(\.path).filter {
                    $0 == row.path || $0.hasPrefix(row.path + "/")
                })
            } else {
                paths.append(row.path)
            }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func revealBrowsed(_ row: FurlBrowserRow, quickLook: Bool) async {
        let opened = browserURL
        guard opened != nil else { return }
        do {
            let entries = try await loadSolidEntries()
            guard browserURL == opened else { return }
            guard let entry = entries.first(where: { $0.path == row.path }) else {
                alertMessage = "\(row.name) is not in this archive."
                return
            }
            let root = try previewDirectory()
            try FurlArchive.writeEntries([entry], into: root)
            let url = try FurlArchive.destination(in: root, forRelative: entry.path)
            if quickLook, let panel = QLPreviewPanel.shared() {
                FurlQuickLook.shared.url = url
                panel.dataSource = FurlQuickLook.shared
                panel.delegate = FurlQuickLook.shared
                panel.reloadData()
                panel.makeKeyAndOrderFront(nil)
                status = "Previewing \(row.name)."
            } else {
                NSWorkspace.shared.open(url)
                status = "Opened \(row.name)."
            }
        } catch {
            guard browserURL == opened else { return }
            noteFailure(error, failed: quickLook ? "Preview failed." : "Open failed.")
        }
    }

    private func extractBrowsed(paths: [String]?, to dest: URL, label: String) async {
        let opened = browserURL
        guard opened != nil else { return }
        do {
            let entries = try await loadSolidEntries()
            guard browserURL == opened else { return }
            let chosen: [FurlEntry]
            if let paths {
                let wanted = Set(paths)
                chosen = entries.filter { wanted.contains($0.path) }
            } else {
                chosen = entries
            }
            guard !chosen.isEmpty else {
                alertMessage = "Nothing to extract."
                return
            }
            let folderName = browserURL?.deletingPathExtension().lastPathComponent ?? "Archive"
            let folder = dest.appendingPathComponent(folderName, isDirectory: true)
            try FurlArchive.writeEntries(chosen, into: folder)
            lastOutput = folder
            status = "Extracted \(chosen.count) item(s) (\(label)) into \(folder.lastPathComponent)."
            progress = 1
        } catch {
            guard browserURL == opened else { return }
            noteFailure(error, failed: "Extract failed.")
        }
    }

    private func loadSolidEntries() async throws -> [FurlEntry] {
        if let materialized { return materialized }
        if let solidLoad { return try await solidLoad.value }
        guard let archiveURL = browserURL else {
            throw FurlError.format("No archive is open.")
        }
        solidGeneration += 1
        let generation = solidGeneration
        let control = beginRun("Reading the solid archive…", .solid)
        let report = progressHandler(control)
        let task = Task { @MainActor in
            defer {
                if self.solidGeneration == generation {
                    self.solidLoad = nil
                    if self.activity == .solid { self.endRun() }
                }
            }
            let entries = try await Task.detached {
                let data = try Data(contentsOf: archiveURL)
                if control.isStopped { throw FurlError.cancelled }
                return try FurlArchive.unpack(data, progress: report)
            }.value
            if self.browserURL == archiveURL && self.solidGeneration == generation {
                self.materialized = entries
            }
            return entries
        }
        solidLoad = task
        return try await task.value
    }

    private func previewDirectory() throws -> URL {
        if let previewRoot { return previewRoot }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("furl-browse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        previewRoot = url
        return url
    }

    func open() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.item, .folder]
        if p.runModal() == .OK {
            add(p.urls)
        }
    }

    func furl() {
        Task { await runFurl() }
    }

    func unfurl() {
        Task { await runUnfurl() }
    }

    func race() {
        Task { await runRace() }
    }

    func revealLast() {
        var urls: [URL] = []
        if let lastOutput { urls.append(lastOutput) }
        if let lastReportURL { urls.append(lastReportURL) }
        if let lastRaceReportURL { urls.append(lastRaceReportURL) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func stop() {
        guard isWorking, !isStopping else { return }
        isStopping = true
        runControl?.stop()
        status = "Stopping…"
    }

    private func beginRun(_ label: String, _ activity: Activity) -> RunControl {
        let control = RunControl()
        runControl = control
        self.activity = activity
        isWorking = true
        isStopping = false
        progress = 0
        status = label
        return control
    }

    private func endRun() {
        isWorking = false
        isStopping = false
        runControl = nil
        activity = nil
    }

    private func noteFailure(_ error: Error, failed: String) {
        if case FurlError.cancelled = error {
            status = "Stopped."
            progress = 0
            return
        }
        alertMessage = error.localizedDescription
        status = failed
    }

    private func progressHandler(_ control: RunControl) -> (UInt64, UInt64) -> Bool {
        { done, total in
            let report = control.report(done: done, total: total)
            if let frac = report.fraction {
                Task { @MainActor in
                    guard self.runControl === control else { return }
                    if frac > self.progress { self.progress = frac }
                }
            }
            return !report.stop
        }
    }

    private func runFurl() async {
        let sources = items.filter { !$0.isArchive }.map(\.url)
        guard !sources.isEmpty else {
            alertMessage = "Add files or folders that are not already .furl archives."
            return
        }
        let dest = saveURL(defaultName: defaultArchiveName(from: sources))
        guard let dest else { return }

        let control = beginRun("Furling…", .furl)
        let level = Int(level)
        let options = gatherOptions
        let wantReport = level >= 9 && writeParseReport
        let report = progressHandler(control)
        lastReportURL = nil
        defer { endRun() }

        do {
            let outcome = try await Task.detached { () -> (Data, DensityReport?, Int) in
                let entries = try FileGather.entries(from: sources, options: options)
                if control.isStopped { throw FurlError.cancelled }
                var parsed: DensityReport?
                let packed = try FurlArchive.pack(entries, level: level, progress: report, parseReport: wantReport ? { parsed = $0 } : nil)
                let orig = entries.reduce(0) { $0 + $1.data.count }
                return (packed, parsed, orig)
            }.value
            let packed = outcome.0
            try packed.write(to: dest, options: .atomic)
            lastOutput = dest
            var reportName: String?
            if let parsed = outcome.1 {
                let reportURL = DensityReport.fileURL(beside: dest)
                do {
                    try parsed.document.write(to: reportURL, atomically: true, encoding: .utf8)
                    lastReportURL = reportURL
                    reportName = reportURL.lastPathComponent
                } catch {
                    alertMessage = "The archive was written. The parse report could not be saved: \(error.localizedDescription)"
                }
            }
            let orig = outcome.2
            let ratio = orig == 0 ? 0 : Double(packed.count) / Double(orig)
            status = "Wrote \(dest.lastPathComponent) · \(pct(ratio)) of original."
            if let reportName {
                status += " Parse report: \(reportName)."
            }
            progress = 1
        } catch {
            noteFailure(error, failed: "Furl failed.")
        }
    }

    private func runUnfurl() async {
        let archives = items.filter(\.isArchive).map(\.url)
        guard let first = archives.first else {
            alertMessage = "Drop a .furl archive to unfurl."
            return
        }
        let destParent = chooseDirectory() ?? first.deletingLastPathComponent()
        let control = beginRun("Unfurling…", .unfurl)
        let report = progressHandler(control)
        defer { endRun() }

        do {
            let outcome = try await Task.detached { () -> (files: Int, output: URL) in
                var used = Set<String>()
                var files = 0
                var onlyFolder: URL?
                for archive in archives {
                    if control.isStopped { throw FurlError.cancelled }
                    let data = try Data(contentsOf: archive)
                    if control.isStopped { throw FurlError.cancelled }
                    let entries = try FurlArchive.unpack(data, progress: report)
                    let base = archive.deletingPathExtension().lastPathComponent
                    let name = distinctFolderName(base, used: &used)
                    let folder = destParent.appendingPathComponent(name, isDirectory: true)
                    try FurlArchive.writeEntries(entries, into: folder)
                    files += entries.count
                    onlyFolder = folder
                }
                if archives.count == 1, let onlyFolder {
                    return (files, onlyFolder)
                }
                return (files, destParent)
            }.value
            lastOutput = outcome.output
            lastReportURL = nil
            if archives.count == 1 {
                status = "Unfurled \(outcome.files) file(s) into \(outcome.output.lastPathComponent)."
            } else {
                status = "Unfurled \(outcome.files) file(s) from \(archives.count) archives into \(destParent.lastPathComponent)."
            }
            progress = 1
        } catch {
            noteFailure(error, failed: "Unfurl failed.")
        }
    }

    var canReveal: Bool {
        lastOutput != nil || lastReportURL != nil || lastRaceReportURL != nil
    }

    private func runRace() async {
        let racers = items.filter { !$0.isArchive }
        guard let first = racers.first else { return }
        let sources = racers.map(\.url)
        let saveReport = writeRaceReport
        let reportURL = SevenZipRace.reportURL(beside: first.url, isDirectory: first.isDirectory, single: racers.count == 1)
        let control = beginRun("Racing ZIP and 7-Zip…", .race)
        let level = max(Int(self.level), 7)
        let options = gatherOptions
        let report = progressHandler(control)
        defer { endRun() }

        do {
            let result = try await Task.detached {
                let entries = try FileGather.entries(from: sources, options: options)
                if control.isStopped { throw FurlError.cancelled }
                return try SevenZipRace.race(entries: entries, level: level, progress: report)
            }.value
            lastRace = result
            var line = raceStatus(result)
            if saveReport {
                do {
                    try result.document.write(to: reportURL, atomically: true, encoding: .utf8)
                    lastRaceReportURL = reportURL
                    line += " Results: \(reportURL.lastPathComponent)."
                } catch {
                    lastRaceReportURL = nil
                    alertMessage = "The race finished. The results file could not be saved: \(error.localizedDescription)"
                }
            } else {
                lastRaceReportURL = nil
            }
            status = line
            progress = 1
        } catch {
            noteFailure(error, failed: "Race failed.")
        }
    }

    private func raceStatus(_ result: RaceResult) -> String {
        var parts = ["Furl \(bytes(result.furlBytes))"]
        if let zip = result.zipBytes {
            parts.append("ZIP \(bytes(zip))")
        } else {
            parts.append("ZIP unavailable")
        }
        if let rival = result.rivalBytes {
            parts.append("\(result.rivalShortName) \(bytes(rival))")
        }
        let tail = result.verdict == "Tie" ? "Tie." : "\(result.verdict) wins."
        return parts.joined(separator: " · ") + " " + tail
    }

    private func defaultArchiveName(from urls: [URL]) -> String {
        if urls.count == 1 {
            let u = urls[0]
            if u.hasDirectoryPath {
                return u.lastPathComponent + ".furl"
            }
            return u.deletingPathExtension().lastPathComponent + ".furl"
        }
        return "Archive.furl"
    }

    private func saveURL(defaultName: String) -> URL? {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "furl") ?? .data]
        p.nameFieldStringValue = defaultName
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }

    private func chooseDirectory(prompt: String = "Unfurl Here") -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = prompt
        return p.runModal() == .OK ? p.url : nil
    }

    private func refreshSizes() {
        for index in items.indices where items[index].isDirectory {
            if let size = try? directorySize(items[index].url) {
                items[index].bytes = size
            }
        }
    }

    private func directorySize(_ url: URL) throws -> Int {
        var total = 0
        let opts = gatherOptions
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]) {
            for case let file as URL in e {
                if FileGather.shouldSkip(file, options: opts) {
                    let dir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    if dir { e.skipDescendants() }
                    continue
                }
                let v = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if v.isRegularFile == true {
                    total += v.fileSize ?? 0
                }
            }
        }
        return total
    }
}

private func distinctFolderName(_ base: String, used: inout Set<String>) -> String {
    if used.insert(base).inserted { return base }
    var n = 2
    while true {
        let name = "\(base)-\(n)"
        if used.insert(name).inserted { return name }
        n += 1
    }
}

func bytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

func pct(_ ratio: Double) -> String {
    String(format: "%.1f%%", ratio * 100)
}
