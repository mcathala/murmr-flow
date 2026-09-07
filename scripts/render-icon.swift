// Rasterise an SVG into a macOS .iconset directory.
//
//   swift scripts/render-icon.swift <in.svg> <out.iconset>
//
// AppKit reads SVG natively (macOS 11+), which is what lets the icon be built with no
// tooling beyond the Command Line Tools — the same constraint as the rest of the build.
import AppKit

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: render-icon.swift <in.svg> <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let source = URL(fileURLWithPath: args[1])
let iconset = URL(fileURLWithPath: args[2])

guard let image = NSImage(contentsOf: source) else {
    FileHandle.standardError.write("could not read \(source.path)\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Every entry `iconutil` accepts. The point size is the name; the pixel size is the file.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: entry.pixels, pixelsHigh: entry.pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { exit(1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(x: 0, y: 0, width: entry.pixels, height: entry.pixels),
        from: .zero, operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: iconset.appendingPathComponent("\(entry.name).png"))
}
