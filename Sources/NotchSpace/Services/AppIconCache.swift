import AppKit
import Foundation

@MainActor
public final class AppIconCache {
    public static let shared = AppIconCache()

    private var cache: [String: NSImage] = [:]

    private init() {}

    public func icon(bundleID: String, appName: String) -> NSImage {
        let normalizedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = normalizedBundle.isEmpty ? "name:\(normalizedName)" : "bundle:\(normalizedBundle)"

        if let cached = cache[key] {
            return cached
        }

        let resolved = resolveIcon(bundleID: normalizedBundle, appName: normalizedName)
        cache[key] = resolved
        return resolved
    }

    private func resolveIcon(bundleID: String, appName: String) -> NSImage {
        if !bundleID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let img = NSWorkspace.shared.icon(forFile: appURL.path)
            img.size = NSSize(width: 32, height: 32)
            return img
        }

        if let running = NSWorkspace.shared.runningApplications.first(where: { app in
            if !bundleID.isEmpty, app.bundleIdentifier == bundleID { return true }
            if !appName.isEmpty, app.localizedName?.lowercased() == appName { return true }
            return false
        }), let img = running.icon {
            let copy = (img.copy() as? NSImage) ?? img
            copy.size = NSSize(width: 32, height: 32)
            return copy
        }

        if let symbol = NSImage(systemSymbolName: "macwindow", accessibilityDescription: appName) {
            return symbol
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
