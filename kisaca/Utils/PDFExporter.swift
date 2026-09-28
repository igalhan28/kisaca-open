//
//  PDFExporter.swift
//  kisaca
//
//  Renders a session's pages (or an explicit subset) into a single multi-page A4
//  PDF, per the project brief's "exporting selected / all pages to PDF" requirement:
//    - `pageIndices` lets the caller export an explicit subset (in the given order)
//      instead of always exporting every page. `nil` = every page.
//    - `fileName` lets the caller name the PDF after the lecture/section/date instead
//      of a generic timestamped name.
//

import Foundation
import PaperKit
import UIKit

/// Renders notebook pages into a single multi-page A4 PDF.
@available(iOS 26.0, *)
@MainActor
enum PDFExporter {

    /// Render scale for high-resolution export (3× = 1785×2526 px per page).
    private static let renderScale: CGFloat = 3.0

    /// Generates a PDF from the given repository.
    ///
    /// Because `PaperMarkup.draw(in:)` is `async`, each page's ink is first rendered
    /// into a `UIImage` asynchronously. Those images are then assembled into a
    /// multi-page PDF synchronously via `UIGraphicsPDFRenderer`.
    ///
    /// - Parameters:
    ///   - repository:   The session's page repository whose pages will be rendered.
    ///   - activeMarkup: The live in-memory markup for the active page (so an
    ///                   unsaved in-progress edit is still included).
    ///   - activeIndex:  Index of the page whose live markup is provided.
    ///   - pageIndices:  Explicit, ordered list of page indices to include. `nil`
    ///                   (the default) exports every page in the repository, in
    ///                   order — this is "Export All". A subset is "Export Selected".
    ///   - fileName:     Desired PDF file name (without extension). Falls back to a
    ///                   timestamped default if `nil`.
    /// - Returns: A temporary file `URL` pointing to the generated PDF.
    static func generatePDF(
        from repository: PageRepository,
        activeMarkup: PaperMarkup?,
        activeIndex: Int,
        pageIndices: [Int]? = nil,
        fileName: String? = nil
    ) async -> URL {
        let a4Rect = PageGeometry.a4Bounds
        let indices = pageIndices ?? Array(0..<repository.pageCount)

        // Step 1 – Render every requested page's ink asynchronously into a UIImage.
        // Ink only, on a transparent background: the grid is drawn as vectors in
        // step 2, so it stays sharp at any zoom in a PDF viewer.
        var pageImages: [UIImage?] = []
        for i in indices {
            let markup: PaperMarkup
            if i == activeIndex, let live = activeMarkup {
                markup = live
            } else {
                markup = repository.loadMarkup(forPageAt: i)
            }
            pageImages.append(
                await PageRenderer.renderInk(markup, scale: renderScale, whiteBackground: false))
        }

        // Step 2 – Assemble into a multi-page PDF (synchronous): white paper, vector
        // grid, then the page's ink on top.
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: a4Rect, format: format)
        let data = renderer.pdfData { context in
            for (image, index) in zip(pageImages, indices) {
                context.beginPage()
                UIColor.white.setFill()
                context.fill(a4Rect)
                PageRenderer.drawGrid(
                    in: context.cgContext, spacing: repository.gridSpacing(forPageAt: index))
                image?.draw(in: a4Rect)
            }
        }

        // Step 3 – Write to a temp file and return the URL.
        let tempDir = FileManager.default.temporaryDirectory
        let name = (fileName ?? "KISACA Notebook \(formattedDate())")
            .replacingOccurrences(of: "/", with: "-")
        let url = tempDir.appendingPathComponent("\(name).pdf")
        try? data.write(to: url)
        return url
    }

    // MARK: - Private helpers

    private static func formattedDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: Date())
    }
}
