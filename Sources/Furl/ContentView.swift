import FurlCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fileArea
            Divider()
            controls
            if let race = model.lastRace {
                Divider()
                racePanel(race)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.accent)
        .onFileDrop { model.add($0) }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            acceptFileDrop(providers)
        }
        .alert("Furl", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.primaryFill)
                    .frame(width: 40, height: 40)
                Image(systemName: "sailboat.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Furl")
                    .font(.title2.weight(.semibold))
                Text("Custom LZ + context-mixing compressor · race it against 7-Zip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 84)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
    }

    private var fileArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            dropZone
            if model.listing != nil {
                FurlArchiveBrowser()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                Text("No files yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                List {
                    ForEach(model.items) { item in
                        HStack {
                            Image(systemName: item.isDirectory ? "folder.fill" : (item.isArchive ? "sailboat.fill" : "doc.fill"))
                                .foregroundStyle(item.isArchive ? Theme.copper : Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                Text(item.sizeLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            if item.isArchive, !item.isDirectory {
                                model.browse(item.url)
                            }
                        }
                    }
                    .onDelete { model.items.remove(atOffsets: $0) }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    dropTarget ? Theme.accent : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: dropTarget ? 2.5 : 1.5, dash: [8, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(dropTarget ? Theme.accent.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                )
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text("Drop files or folders")
                    .font(.headline)
                Text("Furl packs them into a solid .furl archive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(minHeight: 108)
    }

    private func acceptFileDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await fileURL(from: provider) {
                    urls.append(url)
                }
            }
            model.add(urls)
        }
        return true
    }

    private func fileURL(from provider: NSItemProvider) async -> URL? {
        let type = "public.file-url"
        let item = try? await provider.loadItem(forTypeIdentifier: type)
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data, let raw = String(data: data, encoding: .utf8) {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: text), url.isFileURL { return url }
            if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        }
        return nil
    }

    private var controls: some View {
        if model.listing != nil {
            return AnyView(browserControls)
        }
        return AnyView(packControls)
    }

    private var browserControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button("Back") { model.closeBrowser() }
                    .buttonStyle(FurlButtonStyle())
                    .disabled(model.isWorking)
                Button("Open") { model.browserOpenSelection() }
                    .buttonStyle(FurlButtonStyle())
                    .disabled(model.isWorking || model.browserSelection.isEmpty)
                Button("Quick Look") { model.browserQuickLookSelection() }
                    .buttonStyle(FurlButtonStyle())
                    .disabled(model.isWorking || model.browserSelection.isEmpty)
                Button("Extract") { model.browserExtractSelection() }
                    .buttonStyle(FurlButtonStyle(kind: .primary))
                    .disabled(model.isWorking || model.browserSelection.isEmpty)
                Button("Extract All") { model.browserExtractAll() }
                    .buttonStyle(FurlButtonStyle())
                    .disabled(model.isWorking)
                Spacer()
            }
            if model.isWorking {
                workingRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var packControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Density")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Slider(value: $model.level, in: 1...9, step: 1)
                    .disabled(model.isWorking)
                Text("\(Int(model.level))")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .frame(width: 24)
                Text(Int(model.level) >= 7 ? "Dense" : Int(model.level) <= 3 ? "Fast" : "Balanced")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button("Furl") { model.furl() }
                    .buttonStyle(FurlButtonStyle(kind: .primary))
                    .disabled(!model.canFurl)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Unfurl") { model.unfurl() }
                    .buttonStyle(FurlButtonStyle())
                    .disabled(!model.canUnfurl)
                Button("Race 7-Zip") { model.race() }
                    .buttonStyle(FurlButtonStyle(kind: .compact))
                    .disabled(!model.canRace)
                Spacer()
                Button("Browse") { model.browseLatestArchive() }
                    .buttonStyle(FurlButtonStyle())
                    .disabled(!model.canBrowse)
                Button("Add…") { model.open() }
                    .buttonStyle(FurlButtonStyle())
                    .disabled(model.isWorking)
                    .keyboardShortcut("o", modifiers: .command)
                Button("Clear") { model.clear() }
                    .buttonStyle(FurlButtonStyle())
                    .disabled(model.isWorking || model.items.isEmpty)
            }
            if model.isWorking {
                workingRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var workingRow: some View {
        HStack(spacing: 10) {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
            Button("Stop") { model.stop() }
                .buttonStyle(FurlButtonStyle())
                .disabled(model.isStopping)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop the current Furl, Unfurl, or race")
        }
    }

    private func racePanel(_ race: RaceResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Race")
                    .font(.headline)
                Spacer()
                if let rival = race.rivalBytes, rival == race.furlBytes {
                    Text("Tie")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(Theme.navy)
                        .clipShape(Capsule())
                } else if let won = race.furlWon {
                    Text(won ? "Furl wins" : "7-Zip wins")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(won ? Theme.teal : Theme.copper)
                        .clipShape(Capsule())
                }
            }
            HStack(spacing: 16) {
                metric("Original", bytes(race.originalBytes), "100%")
                metric("Furl", bytes(race.furlBytes), pct(race.furlRatio), detail: String(format: "%.2fs", race.furlSeconds))
                metric(
                    race.rivalName,
                    race.rivalBytes.map(bytes) ?? "—",
                    race.rivalRatio.map(pct) ?? "—",
                    detail: race.rivalSeconds.map { String(format: "%.2fs", $0) }
                )
            }
        }
        .padding(16)
    }

    private func metric(_ title: String, _ value: String, _ sub: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(value)
                .font(.title3.weight(.semibold))
            HStack(spacing: 6) {
                Text(sub).font(.caption.monospacedDigit())
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if model.lastOutput != nil {
                Button("Show in Finder") { model.revealLast() }
                    .buttonStyle(FurlButtonStyle(kind: .compact))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
