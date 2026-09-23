// アプリアイコン生成スクリプト。ビルドのたびには実行しない。
// 実行: swift scripts/make-icon.swift
// 生成物 (Resources/AppIcon.icns) はリポジトリにコミットする。
import AppKit

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let iconsetURL = root.appendingPathComponent("Resources/AppIcon.iconset")
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func whiteSilhouette(of symbolName: String, pointSize: CGFloat) -> NSImage? {
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return nil }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    let configured = symbol.withSymbolConfiguration(config) ?? symbol
    let size = configured.size
    let result = NSImage(size: size)
    result.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: size).fill()
    configured.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
    result.unlockFocus()
    return result
}

func render(size: Int) -> Data? {
    let canvas = NSImage(size: NSSize(width: size, height: size))
    canvas.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = CGFloat(size) * 0.225
    let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.27, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.08, alpha: 1)
    )
    gradient?.draw(in: background, angle: -90)

    if let glyph = whiteSilhouette(of: "laptopcomputer", pointSize: CGFloat(size) * 0.5) {
        let origin = NSPoint(x: (CGFloat(size) - glyph.size.width) / 2, y: (CGFloat(size) - glyph.size.height) / 2 + CGFloat(size) * 0.02)
        glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 0.92)
    }

    // 「ブラックアウト」を示す斜線バー。
    let barHeight = max(CGFloat(size) * 0.06, 2)
    let barRect = NSRect(x: CGFloat(size) * 0.16, y: CGFloat(size) * 0.30, width: CGFloat(size) * 0.68, height: barHeight)
    let transform = NSAffineTransform()
    transform.translateX(by: CGFloat(size) / 2, yBy: CGFloat(size) / 2)
    transform.rotate(byDegrees: -35)
    transform.translateX(by: -CGFloat(size) / 2, yBy: -CGFloat(size) / 2)
    transform.concat()
    NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.28, alpha: 0.95).setFill()
    NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

for entry in sizes {
    guard let png = render(size: entry.px) else {
        FileHandle.standardError.write("failed to render \(entry.name)\n".data(using: .utf8)!)
        exit(1)
    }
    let fileURL = iconsetURL.appendingPathComponent("\(entry.name).png")
    try png.write(to: fileURL)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.removeItem(at: iconsetURL)
print("wrote \(icnsURL.path)")
