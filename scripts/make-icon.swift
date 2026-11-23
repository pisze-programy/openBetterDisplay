import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the 1024px master icon for openBetterDisplay:
// A sleek macOS squircle tile featuring an ultra-wide display silhouette,
// vivid ambient HDR glow, and a calibrated brightness indicator.
// Run via scripts/make-icon.sh.

let side = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("Failed to create CGContext\n".utf8))
    exit(1)
}

// 1. Background Squircle Tile (macOS icon standard: margin 90, corner radius ~190)
let margin = 90.0
let tile = CGRect(x: margin, y: margin, width: Double(side) - margin * 2, height: Double(side) - margin * 2)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 190, cornerHeight: 190, transform: nil)
ctx.addPath(tilePath)
ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)) // Deep night slate
ctx.fillPath()

// Border stroke on squircle tile for crisp contrast
ctx.addPath(tilePath)
ctx.setStrokeColor(CGColor(srgbRed: 0.22, green: 0.25, blue: 0.32, alpha: 0.5))
ctx.setLineWidth(4.0)
ctx.strokePath()

// 2. Ambient Screen Glow
let glowCenter = CGPoint(x: 512, y: 550)
let glowRadius = 260.0
let glowRect = CGRect(x: glowCenter.x - glowRadius, y: glowCenter.y - glowRadius, width: glowRadius * 2, height: glowRadius * 2)
ctx.saveGState()
ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 0.25))
ctx.fillEllipse(in: glowRect)
ctx.restoreGState()

// 3. Monitor Stand Base & Neck
// Neck
let neckRect = CGRect(x: 488, y: 280, width: 48, height: 110)
let neckPath = CGPath(roundedRect: neckRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
ctx.addPath(neckPath)
ctx.setFillColor(CGColor(srgbRed: 0.28, green: 0.32, blue: 0.40, alpha: 1.0))
ctx.fillPath()

// Base
let baseRect = CGRect(x: 412, y: 260, width: 200, height: 26)
let basePath = CGPath(roundedRect: baseRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
ctx.addPath(basePath)
ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.40, blue: 0.50, alpha: 1.0))
ctx.fillPath()

// 4. Ultrawide Curved Display Bezel (Outer)
let monitorWidth = 660.0
let monitorHeight = 360.0
let monitorX = (Double(side) - monitorWidth) / 2.0
let monitorY = 370.0
let monitorOuterRect = CGRect(x: monitorX, y: monitorY, width: monitorWidth, height: monitorHeight)
let monitorOuterPath = CGPath(roundedRect: monitorOuterRect, cornerWidth: 32, cornerHeight: 32, transform: nil)

ctx.addPath(monitorOuterPath)
ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.21, blue: 0.28, alpha: 1.0))
ctx.fillPath()

ctx.addPath(monitorOuterPath)
ctx.setStrokeColor(CGColor(srgbRed: 0.40, green: 0.46, blue: 0.58, alpha: 0.6))
ctx.setLineWidth(3.0)
ctx.strokePath()

// 5. Active Screen Panel (Inner)
let screenInset = 16.0
let screenRect = monitorOuterRect.insetBy(dx: screenInset, dy: screenInset)
let screenPath = CGPath(roundedRect: screenRect, cornerWidth: 20, cornerHeight: 20, transform: nil)

ctx.saveGState()
ctx.addPath(screenPath)
ctx.clip()

// Screen Background (Deep navy gradient feel)
ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.08, blue: 0.15, alpha: 1.0))
ctx.fill(screenRect)

// Screen Artwork: Stylized Horizon / Vibrant Curved Arc representing HDR / Brightness
let sunCenter = CGPoint(x: 512, y: 530)
let sunRadius = 70.0
let sunGlowRect = CGRect(x: sunCenter.x - 110, y: sunCenter.y - 110, width: 220, height: 220)
ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.65, blue: 1.00, alpha: 0.30))
ctx.fillEllipse(in: sunGlowRect)

// Core Sun
let sunCoreRect = CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2)
ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.75, blue: 0.95, alpha: 1.0))
ctx.fillEllipse(in: sunCoreRect)

// Warm Sun Accent (Night Shift blend)
let warmRect = CGRect(x: sunCenter.x - 45, y: sunCenter.y - 45, width: 90, height: 90)
ctx.setFillColor(CGColor(srgbRed: 1.00, green: 0.70, blue: 0.25, alpha: 0.90))
ctx.fillEllipse(in: warmRect)

// Calibration / Slider Arc
let arcRect = CGRect(x: sunCenter.x - 130, y: sunCenter.y - 130, width: 260, height: 260)
ctx.setStrokeColor(CGColor(srgbRed: 0.30, green: 0.85, blue: 0.95, alpha: 0.75))
ctx.setLineWidth(8.0)
ctx.strokeEllipse(in: arcRect)

ctx.restoreGState()

// 6. Chin indicator (small power / DDC LED)
let ledRect = CGRect(x: 508, y: monitorY + 5, width: 8, height: 5)
let ledPath = CGPath(roundedRect: ledRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
ctx.addPath(ledPath)
ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.80, blue: 0.50, alpha: 0.9))
ctx.fillPath()

// 7. Output image
guard let image = ctx.makeImage() else {
    FileHandle.standardError.write(Data("Could not render icon image\n".utf8))
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let outputURL = URL(fileURLWithPath: outputPath) as CFURL
guard let destination = CGImageDestinationCreateWithURL(outputURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("Could not create image destination for \(outputPath)\n".utf8))
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("Could not write \(outputPath)\n".utf8))
    exit(1)
}

print(outputPath)
