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
        window.makeKeyAndOrderFront(nil)
    }
}
