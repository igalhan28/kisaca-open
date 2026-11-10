//
//  PageGeometry.swift
//  kisaca
//
//  A4 page geometry, shared by the notebook canvas and the PDF exporter. Kept as its
//  own tiny file rather than a `static let` on whichever view controller happens to
//  own it this iteration — that constant has moved twice already as the canvas was
//  rebuilt, dragging stale doc comments with it each time.
//

import PaperKit
import UIKit

nonisolated enum PageGeometry {
    static let a4Size = CGSize(width: 595, height: 842)
    static var a4Bounds: CGRect { CGRect(origin: .zero, size: a4Size) }

    /// Markup points per page point for pages created by this build.
    ///
    /// Everything in the app — layout, grid, thumbnails, PDF — works in page points
    /// (`a4Size`). The ink does not have to: pen widths, text sizes and shape strokes
    /// are in the markup's own coordinates, and a 595-point-wide markup stretched to
    /// fit an iPad's width magnified every stroke about 1.6× — pens read noticeably
    /// thicker than in Notes, which draws at one ink point per screen point. A 1.6×
    /// larger markup space puts the thinnest pen back at Notes' width on a 13" iPad in
    /// portrait (fit-to-width ≈ 952 pt).
    ///
    /// Pages written before this keep their 595×842 markup: each page's markup stores
    /// its own `bounds`, and `PaperMarkup.inkScale` reads it back, so old ink keeps
    /// exactly the size and position it was drawn at.
    static let inkScale: CGFloat = 1.6
    static var newMarkupBounds: CGRect {
        CGRect(x: 0, y: 0, width: a4Size.width * inkScale, height: a4Size.height * inkScale)
    }

    /// Grid square side, in page points (1 pt = 1/72 in), for a side of `millimeters`.
    /// The size is per session (`LectureSession.gridSpacingMM`); the live canvas, the
    /// placeholder tiles and the PDF export all convert it here so they draw the same
    /// paper.
    static func gridSpacing(millimeters: Double) -> CGFloat {
        CGFloat(millimeters) * 72 / 25.4
    }
    /// Grid line width, in page points. Scales with the page like the ink does; on
    /// screen it is rounded to whole device pixels (never less than one).
    static let gridLineWidth: CGFloat = 0.5
    /// Opaque: the pale blue that 30% blue used to give on white, without the
    /// transparency — overlapping line layers on screen would otherwise darken where
    /// they cross. The paper is always white, so nothing else changes.
    static let gridColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.2)
}

extension PaperMarkup {
    /// An empty page in this build's markup space.
    nonisolated static func blankPage() -> PaperMarkup {
        PaperMarkup(bounds: PageGeometry.newMarkupBounds)
    }

    /// Markup points per page point for this page: 1 for pages from before
    /// `PageGeometry.inkScale`, `PageGeometry.inkScale` for new ones.
    nonisolated var inkScale: CGFloat {
        bounds.width > 0 ? bounds.width / PageGeometry.a4Size.width : 1
    }
}
