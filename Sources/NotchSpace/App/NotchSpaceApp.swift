import AppKit

@MainActor
final class NotchSpaceAppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.paneruClient.stop()
    }
}

@main
@MainActor
enum NotchSpaceMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = NotchSpaceAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
