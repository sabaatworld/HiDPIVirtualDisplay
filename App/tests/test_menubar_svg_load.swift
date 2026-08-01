import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fatalError("Usage: test_menubar_svg_load.swift <path to MenuBarIcon.svg>")
}

let url = URL(fileURLWithPath: arguments[1])
guard let image = NSImage(contentsOf: url) else {
    fatalError("MenuBarIcon.svg could not be loaded by NSImage")
}

image.size = NSSize(width: 18, height: 18)
image.isTemplate = true
precondition(image.isTemplate)
precondition(image.size == NSSize(width: 18, height: 18))
