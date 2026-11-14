import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the Nudge app icon: the letter "n" in braille (dots 1, 3, 4, 5) in tactile-paving
// yellow on black. Usage: swift main.swift <output.png> [size]
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024
let s = CGFloat(size)

let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: s, height: s))

let pattern: [[Bool]] = [[true, true], [false, true], [true, false]]   // rows top to bottom
let dot = s * 0.176
let gap = s * 0.104
let cellWidth = dot * 2 + gap
let cellHeight = dot * 3 + gap * 2
let originX = (s - cellWidth) / 2
let originTop = (s - cellHeight) / 2

for row in 0..<3 {
    for column in 0..<2 {
        let x = originX + CGFloat(column) * (dot + gap)
        // Core Graphics counts y upward, so flip the row.
        let y = s - originTop - CGFloat(row) * (dot + gap) - dot
        let lit = pattern[row][column]
        context.setFillColor(lit ? CGColor(red: 1.0, green: 0.82, blue: 0.12, alpha: 1)
                                 : CGColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1))
        context.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
    }
}

let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
