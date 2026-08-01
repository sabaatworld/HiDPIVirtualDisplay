import Foundation

struct IconChunk {
    let type: String
    let filename: String
}

enum CompilerError: Error, LocalizedError {
    case usage
    case invalidPNG(URL)
    case oversizedChunk(URL)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: compile_icns.swift <iconset directory> <output icns>"
        case let .invalidPNG(url):
            return "Expected PNG data in \(url.path)"
        case let .oversizedChunk(url):
            return "Icon chunk is too large to store: \(url.path)"
        }
    }
}

func bigEndianData(_ value: UInt32) -> Data {
    var bigEndian = value.bigEndian
    return Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
}

func fourCharacterData(_ value: String) -> Data {
    Data(value.utf8)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    throw CompilerError.usage
}

let iconsetDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])
let chunks = [
    IconChunk(type: "icp4", filename: "icon_16x16.png"),
    IconChunk(type: "icp5", filename: "icon_32x32.png"),
    IconChunk(type: "icp6", filename: "icon_32x32@2x.png"),
    IconChunk(type: "ic07", filename: "icon_128x128.png"),
    IconChunk(type: "ic08", filename: "icon_256x256.png"),
    IconChunk(type: "ic09", filename: "icon_512x512.png"),
    IconChunk(type: "ic10", filename: "icon_512x512@2x.png"),
]
let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

var payload = Data()
for chunk in chunks {
    let sourceURL = iconsetDirectory.appendingPathComponent(chunk.filename)
    let imageData = try Data(contentsOf: sourceURL)
    guard imageData.starts(with: pngSignature) else {
        throw CompilerError.invalidPNG(sourceURL)
    }
    guard imageData.count <= Int(UInt32.max) - 8 else {
        throw CompilerError.oversizedChunk(sourceURL)
    }

    payload.append(fourCharacterData(chunk.type))
    payload.append(bigEndianData(UInt32(imageData.count + 8)))
    payload.append(imageData)
}

guard payload.count <= Int(UInt32.max) - 8 else {
    throw CompilerError.oversizedChunk(outputURL)
}

var container = Data()
container.append(fourCharacterData("icns"))
container.append(bigEndianData(UInt32(payload.count + 8)))
container.append(payload)
try container.write(to: outputURL, options: .atomic)
