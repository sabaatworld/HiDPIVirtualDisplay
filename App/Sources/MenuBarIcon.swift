import AppKit

enum MenuBarIcon {
    static func make() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }

        debugLog("Bundled MenuBarIcon.svg could not be loaded; using display symbol")
        let fallback = NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "HiDPI Display"
        )!
        fallback.isTemplate = true
        return fallback
    }
}
