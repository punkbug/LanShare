import AppKit
import CoreGraphics

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: size * 4, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bitmap.setAllowsAntialiasing(true)
bitmap.setShouldAntialias(true)

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}
func fill(_ path: CGPath, _ color: NSColor) {
    bitmap.addPath(path)
    bitmap.setFillColor(color.cgColor)
    bitmap.fillPath()
}
func rounded(_ frame: CGRect, _ radius: CGFloat, _ color: NSColor) {
    fill(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil), color)
}
func polygon(_ points: [(CGFloat, CGFloat)], _ color: NSColor) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.0, y: p.1)) }
    path.closeSubpath()
    fill(path, color)
}

let blue = NSColor(calibratedRed: 0.14, green: 0.34, blue: 0.84, alpha: 1)
let ink = NSColor(calibratedRed: 0.11, green: 0.25, blue: 0.60, alpha: 1)
let accent = NSColor(calibratedRed: 0.30, green: 0.86, blue: 0.98, alpha: 1)

rounded(rect(0, 0, 1024, 1024), 220, blue)

// A clear file page with a folded corner.
let paper = CGMutablePath()
paper.move(to: CGPoint(x: 286, y: 222))
paper.addLine(to: CGPoint(x: 286, y: 768))
paper.addQuadCurve(to: CGPoint(x: 326, y: 808), control: CGPoint(x: 286, y: 808))
paper.addLine(to: CGPoint(x: 592, y: 808))
paper.addLine(to: CGPoint(x: 738, y: 662))
paper.addLine(to: CGPoint(x: 738, y: 262))
paper.addQuadCurve(to: CGPoint(x: 698, y: 222), control: CGPoint(x: 738, y: 222))
paper.closeSubpath()
fill(paper, .white)
polygon([(592, 808), (592, 702), (698, 702)], NSColor(calibratedRed: 0.82, green: 0.88, blue: 1, alpha: 1))

// Short document lines remain visible above the transfer symbol.
rounded(rect(362, 618, 250, 24), 12, NSColor(calibratedRed: 0.70, green: 0.77, blue: 0.90, alpha: 1))
rounded(rect(362, 558, 190, 24), 12, NSColor(calibratedRed: 0.70, green: 0.77, blue: 0.90, alpha: 1))

// Two bold, opposing arrows communicate sending and receiving at a glance.
polygon([(354, 448), (444, 448), (444, 492), (544, 492), (544, 452), (604, 512), (544, 572), (544, 532), (400, 532), (400, 488), (354, 488)], ink)
polygon([(670, 388), (580, 388), (580, 344), (480, 344), (480, 384), (420, 324), (480, 264), (480, 304), (624, 304), (624, 348), (670, 348)], accent)

let image = bitmap.makeImage()!
let data = NSMutableData()
let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
