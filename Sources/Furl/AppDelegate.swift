import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var pendingURLs: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        configureWindows()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        configureWindows()
    }

    private func configureWindows() {
        for window in NSApp.windows {
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        dispatch(urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        dispatch([URL(fileURLWithPath: filename)])
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        dispatch(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    @MainActor
    func attach(model: AppModel) {
        self.model = model
        flushPending()
    }

    private func dispatch(_ urls: [URL]) {
        Task { @MainActor in
            if let model {
                model.add(urls)
            } else {
                pendingURLs.append(contentsOf: urls)
            }
        }
    }

    @MainActor
    private func flushPending() {
        guard let model, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs.removeAll()
        model.add(urls)
    }
}
