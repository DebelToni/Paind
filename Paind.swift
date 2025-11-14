import Cocoa
import SwiftUI

// MARK: – app bootstrap --------------------------------------------
@main
struct App {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var drawingView: DrawingView?
    func applicationDidFinishLaunching(_: Notification) {
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 750),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = ""
        window.isOpaque = false
        window.backgroundColor = .white
        window.center()

        let view = DrawingView(frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.makeFirstResponder(view)
        drawingView = view

        configureMenus()

        window.makeKeyAndOrderFront(nil)
    }

    private func configureMenus() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(NSMenuItem(title: "About \(appName)", action: nil, keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        fileMenu.addItem(openItem)
        let saveItem = NSMenuItem(title: "Save…", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = [.command]
        saveItem.target = self
        fileMenu.addItem(saveItem)
        fileMenuItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openDocument(_ sender: Any?) {
        drawingView?.openDocumentFromMenu()
    }

    @objc private func saveDocument(_ sender: Any?) {
        drawingView?.saveDocumentFromMenu()
    }
}
