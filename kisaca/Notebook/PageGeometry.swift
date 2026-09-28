//
//  PageGeometry.swift
//  kisaca
//
//  A4 page geometry, shared by the notebook canvas and the PDF exporter. Kept as its
//  own tiny file rather than a `static let` on whichever view controller happens to
//  own it this iteration — that constant has moved twice already as the canvas was
//  rebuilt, dragging stale doc comments with it each time.
//

import UIKit

enum PageGeometry {
    static let a4Size = CGSize(width: 595, height: 842)
    static var a4Bounds: CGRect { CGRect(origin: .zero, size: a4Size) }

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
    static let gridColor = UIColor(red: 0.7, green: 0.7, blue: 1, alpha: 1)
}
