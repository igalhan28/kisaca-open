//
//  GridBackground.swift
//  kisaca
//
//  The paper's squared grid, drawn on screen. One per page tile, underneath the
//  live canvas — the canvas itself is transparent and draws no grid of its own.
//

import UIKit

/// Draws the page grid as one thin solid-colour layer per line, with every line's
/// edges rounded to whole device pixels.
///
/// **Why layers, not `draw(_:)`.** The grid used to be a `draw(_:)` bitmap, and was
/// blurry: measured in the simulator, each line was smeared across 3–4 pixels with
/// a different intensity profile per line. Two reasons, both structural:
///
/// 1. On the live canvas the grid was PaperKit's `contentView`, drawn once at A4
///    size (595 pt) and then *magnified* by PaperKit to the tile's size — a bitmap
///    scaled up is blurry by construction, at every zoom but 1.
/// 2. The square side (5 mm × zoom) is almost never a whole number of pixels, so
///    lines fall between pixels and get antialiased across two or three.
///
/// A layer with only a `backgroundColor` has no backing bitmap at all — it costs no
/// memory however far the page is zoomed (a bitmap of a 6×-zoomed page would be
/// hundreds of MB) and Core Animation fills it exactly on the pixels its frame
/// covers. So each line's frame is snapped to device pixels here, and the grid is
/// sharp at every zoom. That only holds while this view itself sits on whole pixels,
/// which a page shown at a fractional zoom does not always do.
final class UIGridBackgroundView: UIView {

    /// Screen points per page point — the zoom this page is currently shown at.
    var pageScale: CGFloat = 1 {
        didSet { if pageScale != oldValue { setNeedsLayout() } }
    }

    /// Grid square side, in page points.
    var spacing: CGFloat = PageGeometry.gridSpacing(millimeters: LectureSession.legacyGridSpacingMM) {
        didSet { if spacing != oldValue { setNeedsLayout() } }
    }

    private var verticalLines: [CALayer] = []
    private var horizontalLines: [CALayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Pixel snapping depends on the screen's scale (e.g. moved to an external display).
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _) in
            view.setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let pixelsPerPoint = max(traitCollection.displayScale, 1)
        let step = spacing * pageScale  // screen points
        // A grid finer than a few pixels is just a tint — and, zoomed far out, a
        // lot of layers for nothing. Also rejects a NaN/zero scale mid-layout.
        guard step.isFinite, step * pixelsPerPoint >= 3,
            bounds.width > 0, bounds.height > 0
        else {
            resize(&verticalLines, to: 0)
            resize(&horizontalLines, to: 0)
            return
        }

        // Line width in whole pixels, at least one.
        let widthPixels = max(
            (PageGeometry.gridLineWidth * pageScale * pixelsPerPoint).rounded(), 1)
        let width = widthPixels / pixelsPerPoint

        /// The snapped leading edge of a line centred on `position` (screen points).
        func snappedEdge(_ position: CGFloat) -> CGFloat {
            (position * pixelsPerPoint - widthPixels / 2).rounded() / pixelsPerPoint
        }

        let columns = Int((bounds.width / step).rounded(.down)) + 1
        let rows = Int((bounds.height / step).rounded(.down)) + 1

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        resize(&verticalLines, to: columns)
        for (i, line) in verticalLines.enumerated() {
            line.frame = CGRect(
                x: snappedEdge(CGFloat(i) * step), y: 0, width: width, height: bounds.height)
        }
        resize(&horizontalLines, to: rows)
        for (i, line) in horizontalLines.enumerated() {
            line.frame = CGRect(
                x: 0, y: snappedEdge(CGFloat(i) * step), width: bounds.width, height: width)
        }
        CATransaction.commit()
    }

    private func resize(_ lines: inout [CALayer], to count: Int) {
        while lines.count > count { lines.removeLast().removeFromSuperlayer() }
        while lines.count < count {
            let line = CALayer()
            // Opaque, so a crossing of two lines is no darker than either line.
            line.backgroundColor = PageGeometry.gridColor.cgColor
            // Mid-pinch the scroll view shrinks the page by a transform, and a line
            // thinner than a pixel with edge antialiasing off (the default) is either
            // dropped or drawn whole — measured, some lines vanished and the grid read
            // as irregular clusters for the frames after the fingers lift. With it
            // on, a sub-pixel line draws faint instead. At rest the edges sit on
            // pixel boundaries, so this changes nothing there.
            line.allowsEdgeAntialiasing = true
            layer.addSublayer(line)
            lines.append(line)
        }
    }
}
