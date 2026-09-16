import AppKit

extension NSBitmapImageRep {
    /// A plain 8-bit RGBA bitmap of `pixelsWide` x `pixelsHigh`, which is what every icon render in
    /// this app draws into. Nine of the ten arguments never vary, so only the two that do are asked
    /// for here.
    static func rgba(pixelsWide: Int, pixelsHigh: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }
}
