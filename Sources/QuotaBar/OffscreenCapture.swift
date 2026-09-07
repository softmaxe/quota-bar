#if DEBUG
import AppKit
import SwiftUI

/// The `--dump-*` flags all render a view that normally lives in the menu or the settings window
/// off screen and write it to a PNG. `OffscreenCapture` owns that mechanism so each dump only has
/// to build its view and name its file.
@MainActor
enum OffscreenCapture {
    /// The real card sits on the menu's vibrant material, so the dumps are forced dark. But
    /// `cacheDisplay` paints no window background, so the render also needs an opaque ground of its
    /// own — without one the dark-mode text comes out white on white.
    private static let ground = NSColor(white: 0.13, alpha: 1)

    /// The same ground, for the `renderPNG` path: `ImageRenderer` composites no window behind the
    /// view, so those dumps paint it themselves rather than coming out white on white.
    static var groundColor: Color { Color(nsColor: Self.ground) }

    enum Outcome {
        case written(URL)
        case failed(String)
    }

    /// Renders `hosting` at its current frame and writes it to `<root>/<name>.png`.
    ///
    /// `titled` gives the render the window chrome the real view has, and orders that window in for
    /// the capture the way the shipped view is on screen; `settle` runs the run loop first, for a
    /// pane that fills itself in asynchronously.
    static func writePNG(
        _ hosting: NSView,
        named name: String,
        into root: URL,
        titled: Bool = false,
        settle: TimeInterval = 0
    ) -> Outcome {
        guard let rep = Self.render(hosting, titled: titled, settle: settle) else {
            return .failed("failed to render \(name)")
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return .failed("failed to encode \(name)")
        }
        let url = root.appendingPathComponent("\(name).png")
        try? data.write(to: url)
        return .written(url)
    }

    /// The same render, handed back as pixels. A verifier compares two of these rather than
    /// writing them out.
    static func render(
        _ hosting: NSView,
        titled: Bool = false,
        settle: TimeInterval = 0
    ) -> NSBitmapImageRep? {
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: titled ? [.titled, .closable] : [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)

        let ground = NSView(frame: hosting.frame)
        ground.wantsLayer = true
        ground.layer?.backgroundColor = Self.ground.cgColor
        ground.addSubview(hosting)
        window.contentView = ground

        if titled {
            window.orderFront(nil)
        }
        if settle > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(settle))
        }
        ground.layoutSubtreeIfNeeded()
        defer {
            if titled {
                window.orderOut(nil)
            }
        }

        guard let rep = ground.bitmapImageRepForCachingDisplay(in: ground.bounds) else {
            return nil
        }
        ground.cacheDisplay(in: ground.bounds, to: rep)
        return rep
    }

    /// Renders `view` at 2x and writes it to `<root>/<name>.png`. Frame dumps use this rather
    /// than `writePNG` because a view frozen at one instant needs no window to lay out in.
    static func renderPNG(_ view: some View, named name: String, into root: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: root.appendingPathComponent("\(name).png"))
    }

    /// `<dir>` as the dumps take it: tilde-expanded and created if it is not there yet.
    nonisolated static func directory(_ path: String) -> URL {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

#endif
