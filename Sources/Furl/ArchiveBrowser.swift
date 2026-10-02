import AppKit
import FurlCore
import Quartz
import SwiftUI

struct FurlArchiveBrowser: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            crumbBar
            Divider()
            if model.browserRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(model.listing == nil ? "Reading the file table…" : "Empty folder")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FurlEntryTable(
                    rows: model.browserRows,
                    selection: $model.browserSelection,
                    onOpen: { model.browserOpen($0) },
                    onQuickLook: { model.browserQuickLook($0) },
                    onExtract: { model.browserExtract($0) }
                )
            }
        }
    }

    private var crumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(crumb.label) { model.browserNavigate(to: crumb.path) }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Theme.accent)
                        .font(.callout.weight(index == crumbs.count - 1 ? .semibold : .regular))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var crumbs: [(label: String, path: String)] {
        let root = model.browserURL?.deletingPathExtension().lastPathComponent ?? "Archive"
        var items = [(label: root, path: "")]
        var built = ""
        for part in model.browserPath.split(separator: "/") {
            built = built.isEmpty ? String(part) : built + "/" + part
            items.append((label: String(part), path: built))
        }
        return items
    }
}

final class FurlQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = FurlQuickLook()
    var url: URL?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as QLPreviewItem?
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        url = nil
    }
}

private struct FurlEntryTable: NSViewRepresentable {
    let rows: [FurlBrowserRow]
    @Binding var selection: Set<String>
    let onOpen: (FurlBrowserRow) -> Void
    let onQuickLook: (FurlBrowserRow) -> Void
    let onExtract: (FurlBrowserRow) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let table = BrowserTable()
        table.style = .fullWidth
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 4)
        table.doubleAction = #selector(Coordinator.openClicked(_:))
        table.target = context.coordinator
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.openSelection() }
        table.onSpace = { [weak coordinator = context.coordinator] in coordinator?.quickLookSelection() }

        addColumn("name", title: "Name", width: 280, min: 160, table: table)
        addColumn("size", title: "Size", width: 90, min: 70, table: table)
        addColumn("modified", title: "Modified", width: 160, min: 120, table: table)
        addColumn("kind", title: "Kind", width: 90, min: 70, table: table)

        let menu = NSMenu()
        menu.addItem(item("Open", #selector(Coordinator.openClicked(_:)), context.coordinator))
        menu.addItem(item("Quick Look", #selector(Coordinator.previewClicked(_:)), context.coordinator))
        menu.addItem(item("Extract…", #selector(Coordinator.extractClicked(_:)), context.coordinator))
        table.menu = menu

        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? BrowserTable else { return }
        let paths = rows.map(\.path)
        if context.coordinator.paths != paths {
            context.coordinator.paths = paths
            table.reloadData()
        }
        context.coordinator.syncSelection()
    }

    private func addColumn(_ id: String, title: String, width: CGFloat, min: CGFloat, table: NSTableView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        table.addTableColumn(column)
    }

    private func item(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: FurlEntryTable
        weak var table: NSTableView?
        var paths: [String] = []
        private var updating = false
        private let dates: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        init(parent: FurlEntryTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < parent.rows.count, let tableColumn else { return nil }
            let entry = parent.rows[row]
            switch tableColumn.identifier.rawValue {
            case "name":
                return nameCell(entry, table: tableView, column: tableColumn)
            case "size":
                let text = entry.isSymlink ? "—" : ByteCountFormatter.string(fromByteCount: Int64(entry.uncompressedSize), countStyle: .file)
                return label(text, id: "size", table: tableView, mono: true)
            case "modified":
                let text = entry.modified.map { dates.string(from: $0) } ?? "—"
                return label(text, id: "modified", table: tableView, mono: false)
            default:
                let kind = entry.isDirectory ? "Folder" : (entry.isSymlink ? "Symlink" : "File")
                return label(kind, id: "kind", table: tableView, mono: false)
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, !updating else { return }
            var next = Set<String>()
            for index in table.selectedRowIndexes where index < parent.rows.count {
                next.insert(parent.rows[index].path)
            }
            if next != parent.selection {
                updating = true
                parent.selection = next
                updating = false
            }
        }

        func syncSelection() {
            guard let table, !updating else { return }
            var indexes = IndexSet()
            for (index, row) in parent.rows.enumerated() where parent.selection.contains(row.path) {
                indexes.insert(index)
            }
            if table.selectedRowIndexes != indexes {
                updating = true
                table.selectRowIndexes(indexes, byExtendingSelection: false)
                updating = false
            }
        }

        @objc func openClicked(_ sender: Any?) { openRow(preferClick: true) }
        @objc func previewClicked(_ sender: Any?) { previewRow(preferClick: true) }
        @objc func extractClicked(_ sender: Any?) {
            guard let row = row(preferClick: true) else { return }
            parent.onExtract(row)
        }

        func openSelection() { openRow(preferClick: false) }
        func quickLookSelection() { previewRow(preferClick: false) }

        private func openRow(preferClick: Bool) {
            guard let row = row(preferClick: preferClick) else { return }
            parent.onOpen(row)
        }

        private func previewRow(preferClick: Bool) {
            guard let row = row(preferClick: preferClick) else { return }
            parent.onQuickLook(row)
        }

        /// A click still has `clickedRow` set after the selection moves. Return and Space follow the selection.
        private func row(preferClick: Bool) -> FurlBrowserRow? {
            guard let table else { return nil }
            let index: Int
            if preferClick, table.clickedRow >= 0 {
                index = table.clickedRow
            } else {
                index = table.selectedRow
            }
            guard index >= 0, index < parent.rows.count else { return nil }
            return parent.rows[index]
        }

        private func nameCell(_ entry: FurlBrowserRow, table: NSTableView, column: NSTableColumn) -> NSView {
            let id = NSUserInterfaceItemIdentifier("name")
            let cell = table.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let view = NSTableCellView()
                view.identifier = id
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingMiddle
                view.addSubview(image)
                view.addSubview(text)
                view.imageView = image
                view.textField = text
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                    image.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    text.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                return view
            }()
            let symbol = entry.isDirectory ? "folder.fill" : (entry.isSymlink ? "link" : "doc")
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.imageView?.contentTintColor = entry.isDirectory ? .systemBlue : .secondaryLabelColor
            cell.textField?.stringValue = entry.name
            return cell
        }

        private func label(_ text: String, id: String, table: NSTableView, mono: Bool) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier(id)
            let field = table.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingTail
                if mono { field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
                field.textColor = .secondaryLabelColor
                return field
            }()
            field.stringValue = text
            return field
        }
    }
}

private final class BrowserTable: NSTableView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty {
            onSpace?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
