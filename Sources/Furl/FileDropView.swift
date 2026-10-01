import AppKit
import SwiftUI

struct FileDropModifier: ViewModifier {
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        content.background(FileDropCatcher(onDrop: onDrop))
    }
}

extension View {
    func onFileDrop(perform: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropModifier(onDrop: perform))
    }
}

private struct FileDropCatcher: NSViewRepresentable {
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> DropNSView {
        let v = DropNSView()
        v.onDrop = onDrop
        return v
    }

    func updateNSView(_ nsView: DropNSView, context: Context) {
        nsView.onDrop = onDrop
    }
}

final class DropNSView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFiles(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasFiles(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = files(from: sender), !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func hasFiles(_ sender: NSDraggingInfo) -> Bool {
        !(files(from: sender)?.isEmpty ?? true)
    }

    private func files(from sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL]
    }
}
