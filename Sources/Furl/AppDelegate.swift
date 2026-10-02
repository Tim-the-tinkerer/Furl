import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var pendingURLs: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A document open already has the main window. An untitled one would be a second window.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

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
            absorbExtraWindows()
        }
    }

    /// Finder’s open still asks SwiftUI for another window. Keep the oldest one.
    func absorbExtraWindows() {
        for delay in [0.0, 0.05, 0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.closeDuplicateWindows()
            }
        }
    }

    private func closeDuplicateWindows() {
        let windows = contentWindows()
        guard let keeper = windows.first else { return }
        for window in windows.dropFirst() {
            window.close()
        }
        if !keeper.isKeyWindow {
            keeper.makeKeyAndOrderFront(nil)
        }
        configureWindows()
    }

    private func contentWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible &&
                window.canBecomeMain &&
                window.level == .normal &&
                !window.isSheet &&
                !(window is NSPanel) &&
                window.styleMask.contains(.titled)
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
