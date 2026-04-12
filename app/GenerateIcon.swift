// Generates a macOS .icns icon: Apple-style rounded rect with "Z" letter
// Run: swift generate_icon.swift <output.icns>

import Cocoa

func generateIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let _ = NSGraphicsContext.current!.cgContext
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.04
    let cornerRadius = size * 0.22
    let innerRect = rect.insetBy(dx: inset, dy: inset)

    // Background: gradient from deep blue to teal
    let path = NSBezierPath(roundedRect: innerRect, xRadius: cornerRadius, yRadius: cornerRadius)

    // Gradient
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.30, alpha: 1.0),  // Deep navy
            NSColor(calibratedRed: 0.00, green: 0.55, blue: 0.65, alpha: 1.0)   // Teal
        ],
        atLocations: [0.0, 1.0],
        colorSpace: .deviceRGB
    )!
    gradient.draw(in: path, angle: -45)

    // Subtle inner shadow / border
    NSColor(white: 1.0, alpha: 0.1).setStroke()
    path.lineWidth = size * 0.01
    path.stroke()

    // "Z" letter
    let fontSize = size * 0.58
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center

    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraphStyle
    ]

    let text = "Z"
    let textSize = text.size(withAttributes: attrs)
    let textRect = CGRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2 - size * 0.01,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect, withAttributes: attrs)

    image.unlockFocus()
    return image
}

func createICNS(outputPath: String) {
    let sizes: [(CGFloat, String)] = [
        (16, "16x16"),
        (32, "16x16@2x"),
        (32, "32x32"),
        (64, "32x32@2x"),
        (128, "128x128"),
        (256, "128x128@2x"),
        (256, "256x256"),
        (512, "256x256@2x"),
        (512, "512x512"),
        (1024, "512x512@2x")
    ]

    let iconsetPath = "/tmp/Zero.iconset"
    let fm = FileManager.default
    try? fm.removeItem(atPath: iconsetPath)
    try! fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

    for (size, name) in sizes {
        let image = generateIcon(size: size)
        let tiffData = image.tiffRepresentation!
        let bitmap = NSBitmapImageRep(data: tiffData)!
        let pngData = bitmap.representation(using: .png, properties: [:])!
        let filename = "icon_\(name).png"
        try! pngData.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(filename)"))
    }

    // Convert iconset to icns
    let proc = Process()
    proc.launchPath = "/usr/bin/iconutil"
    proc.arguments = ["-c", "icns", iconsetPath, "-o", outputPath]
    proc.launch()
    proc.waitUntilExit()

    try? fm.removeItem(atPath: iconsetPath)
    print("Icon created: \(outputPath)")
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Zero.icns"
createICNS(outputPath: output)
