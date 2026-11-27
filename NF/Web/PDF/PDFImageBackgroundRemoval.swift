import CoreGraphics
import Foundation

enum PDFImageBackgroundRemoval {
    static func apply(_ setting: PDFImageAppearance.BackgroundRemoval, to image: CGImage) -> CGImage {
        guard setting.strength.isFinite, setting.tolerance.isFinite else { return image }
        let strength = min(1, max(0, setting.strength / 100))
        let tolerance = Int((min(100, max(0, setting.tolerance)) * 0.96).rounded())
        let width = image.width, height = image.height
        guard strength > 0, width > 0, height > 0, width <= Int.max / 4 / height else { return image }
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func color(_ index: Int) -> (r: Int, g: Int, b: Int)? {
            let offset = index * 4, alpha = Int(pixels[offset + 3])
            guard alpha > 0 else { return nil }
            return (Int(pixels[offset]) * 255 / alpha, Int(pixels[offset + 1]) * 255 / alpha, Int(pixels[offset + 2]) * 255 / alpha)
        }
        func distance(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Int {
            max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
        }
        let corners = [0, width - 1, width * (height - 1), width * height - 1].compactMap(color)
        guard corners.count >= 2 else { return image }
        let neighborhood = max(8, tolerance)
        guard let background = corners.first(where: { candidate in
            corners.filter { distance(candidate, $0) <= neighborhood }.count >= corners.count / 2 + 1
        }) else { return image }

        let feather = max(1, tolerance / 3)
        var visited = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        func isBackground(_ index: Int) -> Bool {
            guard !visited[index], let value = color(index) else { return false }
            return distance(value, background) <= tolerance
        }
        func clearFromEdge(_ seed: Int) {
            guard isBackground(seed) else { return }
            stack.append(seed)
            while let index = stack.popLast() {
                guard isBackground(index) else { continue }
                let row = index / width
                let start = row * width, end = start + width - 1
                var left = index, right = index
                while left > start, isBackground(left - 1) { left -= 1 }
                while right < end, isBackground(right + 1) { right += 1 }
                var aboveRun = false, belowRun = false
                for pixel in left...right {
                    guard let original = color(pixel) else { continue }
                    visited[pixel] = true
                    let difference = distance(original, background)
                    let keep = 1 - strength * min(1, Double(tolerance - difference + 1) / Double(feather))
                    let offset = pixel * 4
                    for component in 0..<4 { pixels[offset + component] = UInt8((Double(pixels[offset + component]) * keep).rounded()) }
                    let above = row > 0 && isBackground(pixel - width)
                    let below = row < height - 1 && isBackground(pixel + width)
                    if above && !aboveRun { stack.append(pixel - width) }
                    if below && !belowRun { stack.append(pixel + width) }
                    aboveRun = above
                    belowRun = below
                }
            }
        }
        for x in 0..<width {
            clearFromEdge(x)
            clearFromEdge((height - 1) * width + x)
        }
        for y in 0..<height {
            clearFromEdge(y * width)
            clearFromEdge(y * width + width - 1)
        }
        return context.makeImage() ?? image
    }
}
