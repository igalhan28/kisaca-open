//
//  PageRenderer.swift
//  kisaca
//
//  Off-screen rendering of one page, shared by the PDF export and by thumbnail
//  regeneration. It renders *ink only*: the paper's grid is never baked into a
//  bitmap. On screen the grid is drawn live by `UIGridBackgroundView` (pixel-snapped
//  at whatever zoom the page is shown), and in a PDF it is drawn as vector lines by
//  `drawGrid(in:)` — a grid baked into an image is only sharp at the one scale it
//  was rendered at, and blurry everywhere else.
//

import PaperKit
import UIKit

@MainActor
enum PageRenderer {

    /// Renders `markup`'s ink at `scale` pixels per page point. With `whiteBackground`
    /// the image is opaque white paper (for JPEG thumbnails); without, everything but
    /// the ink is transparent (for drawing over a vector grid in a PDF).
    ///
    /// Runs off the main thread, always. `PaperMarkup.draw(in:frame:)` is
    /// `nonisolated(nonsending)` — it runs on whatever actor calls it — so while this
    /// type was main-actor-bound, a whole-page render ran on the main thread. The
    /// notebook re-renders a page's thumbnail shortly after the pen pauses, which put
    /// tens of milliseconds of main-thread work right where the next stroke begins:
    /// Pencil touches queue up behind it and the stroke's first segment lags.
    @concurrent
    nonisolated static func renderInk(
        _ markup: PaperMarkup, scale: CGFloat, whiteBackground: Bool
    ) async -> UIImage? {
        let bounds = PageGeometry.a4Bounds
        let pxWidth = Int(bounds.width * scale)
        let pxHeight = Int(bounds.height * scale)
        guard pxWidth > 0, pxHeight > 0,
            let ctx = CGContext(
                data: nil,
                width: pxWidth,
                height: pxHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Flip to UIKit's top-left origin, then scale page points to pixels.
        ctx.translateBy(x: 0, y: CGFloat(pxHeight))
        ctx.scaleBy(x: scale, y: -scale)

        if whiteBackground {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(bounds)
        }
        // The markup has its own coordinate space (see `PageGeometry.inkScale`).
        let inkScale = markup.inkScale
        ctx.scaleBy(x: 1 / inkScale, y: 1 / inkScale)
        await markup.draw(in: ctx, frame: markup.bounds)

        return ctx.makeImage().map { UIImage(cgImage: $0) }
    }

    /// A page thumbnail: the ink render plus its PNG bytes, both made off the main
    /// thread — PNG-encoding a page-sized image is as slow as rendering it.
    @concurrent
    nonisolated static func renderThumbnail(_ markup: PaperMarkup) async -> (
        image: UIImage, png: Data
    )? {
        guard
            let image = await renderInk(
                markup, scale: thumbnailScale, whiteBackground: false),
            let png = image.pngData()
        else { return nil }
        return (image, png)
    }

    /// Pixels per page point for thumbnails — about what a fit-to-width page on an
    /// iPad comes out at.
    nonisolated static let thumbnailScale: CGFloat = 2.5

    /// Draws the page grid as vector lines, in page points, into `ctx` — used for
    /// the PDF, where vector lines stay sharp at any zoom in any PDF viewer.
    static func drawGrid(in ctx: CGContext, spacing step: CGFloat) {
        let bounds = PageGeometry.a4Bounds
        ctx.saveGState()
        ctx.setLineWidth(PageGeometry.gridLineWidth)
        ctx.setStrokeColor(PageGeometry.gridColor.cgColor)
        for x in stride(from: CGFloat(0), through: bounds.width, by: step) {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        for y in stride(from: CGFloat(0), through: bounds.height, by: step) {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
