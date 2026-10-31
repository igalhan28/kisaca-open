//
//  NotebookPageTileView.swift
//  kisaca
//
//  One page's slot in the continuous "parchment" scroll. A tile exists for every
//  page currently near the viewport, but it is deliberately cheap: a white sheet
//  with grid lines, plus the cached ink thumbnail once one has been rendered. Only the
//  few tiles nearest the viewport get a live `PageCanvasController` laid on top —
//  see `NotebookScrollViewController.updateCanvasAssignments` for that bookkeeping.
//
//  Everything that can draw a page shares ONE container, pinned to identical
//  bounds. That is structural, not cosmetic: when the placeholder artwork and the
//  live canvas were positioned independently, any difference between them showed up
//  on screen as two stacked pages at different sizes. Sharing a container makes that
//  state unrepresentable.
//
//  Stacking, bottom to top: white paper → grid → ink thumbnail → live canvas. The
//  grid is the only grid, and it is always shown: thumbnails and the canvas are
//  both transparent ink, so neither needs a grid of its own. (They used to each
//  carry one, and a grid baked into a bitmap is blurry at every size but one.)
//

import UIKit

final class NotebookPageTileView: UIView {

    private let pageContainer = UIView()
    private let grid = UIGridBackgroundView(frame: .zero)
    private let thumbnailView = UIImageView()

    /// The live canvas currently laid over this tile, if it earned one.
    private(set) var canvas: PageCanvasController?

    /// The part of the page the live canvas covers, in page points — `nil` for the
    /// whole page. Zoomed in, the canvas only covers what is on screen (see
    /// `PageCanvasController.visiblePageRect`); the thumbnail shows the rest, so a
    /// pinch-out or a fast scroll never reveals a page with its ink missing.
    var canvasWindow: CGRect? {
        didSet { if canvasWindow != oldValue { setNeedsLayout() } }
    }

    /// While the live canvas fades in over the thumbnail, the thumbnail stays whole.
    private var isFadingInCanvas = false

    /// A snapshot of a canvas that just left this tile, shown until the thumbnail
    /// catches up with it — with the part of the page it covers, in page points.
    ///
    /// Thumbnails are not re-rendered while the user writes on a page whose canvas
    /// covers all of it (that render used to cost the main thread a frame or more,
    /// right as the next stroke began), so when the canvas goes the thumbnail can be
    /// missing the latest ink until a fresh one is rendered. The snapshot is a
    /// render-server copy of what was on screen: no drawing, nearly free.
    private var inkPlaceholder: (view: UIView, pageRect: CGRect)?

    /// Cuts the canvas's area out of the thumbnail, so the two never both draw ink.
    private let thumbnailMask: CAShapeLayer = {
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        return mask
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        // The drop shadow lives on the tile — the tile is what defines where this
        // page sits in the document, so it owns the page's outline. Nothing inside
        // gets a shadow of its own; that is what made a slightly-smaller rendered
        // page read as a separate sheet floating inside this one.
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.masksToBounds = false

        // White regardless of what's on top, so that if the canvas's rendered page
        // ever falls a few points short of the slot, the gap reads as page margin
        // rather than a hole.
        pageContainer.backgroundColor = .white
        pageContainer.clipsToBounds = true
        addSubview(pageContainer)

        pageContainer.addSubview(grid)

        thumbnailView.contentMode = .scaleToFill
        thumbnailView.isUserInteractionEnabled = false
        pageContainer.addSubview(thumbnailView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        pageContainer.frame = bounds

        let inner = pageContainer.bounds
        grid.frame = inner
        thumbnailView.frame = inner

        // The grid is defined in page (document) space, so it scales with the tile —
        // otherwise the squares would stay a fixed size on screen and the grid would
        // visibly get denser the further you zoom in. A 0 or non-finite width mid-
        // layout is fine: the grid draws nothing for a scale it can't use.
        let pageScale = inner.width / PageGeometry.a4Size.width
        grid.pageScale = pageScale
        if let placeholder = inkPlaceholder {
            placeholder.view.frame = placeholder.pageRect.applying(
                CGAffineTransform(scaleX: pageScale, y: pageScale))
        }
        layoutCanvas(pageScale: pageScale)

        // An explicit shadow path: without one, Core Animation derives the shadow
        // from the alpha of every sublayer — including each grid line's — offscreen,
        // every frame.
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    /// Places the canvas over `canvasWindow`, on whole device pixels, and tells it the
    /// page rectangle that frame *actually* covers after snapping — so ink under the
    /// canvas lines up exactly with the grid and the thumbnail around it.
    private func layoutCanvas(pageScale: CGFloat) {
        guard let canvas else {
            updateThumbnailMask()
            return
        }
        let inner = pageContainer.bounds
        guard let window = canvasWindow, pageScale > 0, pageScale.isFinite else {
            canvas.view.frame = inner
            canvas.visiblePageRect = PageGeometry.a4Bounds
            updateThumbnailMask()
            return
        }
        let pixels = max(traitCollection.displayScale, 1)
        let scaled = window.applying(CGAffineTransform(scaleX: pageScale, y: pageScale))
        let minX = (scaled.minX * pixels).rounded(.down) / pixels
        let minY = (scaled.minY * pixels).rounded(.down) / pixels
        let maxX = (scaled.maxX * pixels).rounded(.up) / pixels
        let maxY = (scaled.maxY * pixels).rounded(.up) / pixels
        let frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(inner)
        canvas.view.frame = frame
        canvas.visiblePageRect = frame.applying(
            CGAffineTransform(scaleX: 1 / pageScale, y: 1 / pageScale))
        updateThumbnailMask()
    }

    /// The thumbnail shows wherever the canvas doesn't: nowhere when the canvas
    /// covers the whole page, everywhere but the canvas's frame when it covers a window.
    private func updateThumbnailMask() {
        let covered: CGRect
        if let canvas, !isFadingInCanvas {
            covered = canvas.view.frame
        } else if canvas == nil, let placeholder = inkPlaceholder {
            covered = placeholder.view.frame
        } else {
            thumbnailView.isHidden = false
            thumbnailView.layer.mask = nil
            return
        }
        let bounds = thumbnailView.bounds
        if covered.contains(bounds.insetBy(dx: 0.5, dy: 0.5)) {
            thumbnailView.isHidden = true
            thumbnailView.layer.mask = nil
            return
        }
        thumbnailView.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(rect: thumbnailView.convert(covered, from: pageContainer)))
        thumbnailMask.frame = bounds
        thumbnailMask.path = path.cgPath
        thumbnailView.layer.mask = thumbnailMask
        CATransaction.commit()
    }

    /// Grid square side, in page points — the page's session decides it.
    var gridSpacing: CGFloat {
        get { grid.spacing }
        set { grid.spacing = newValue }
    }

    /// Setting it also retires the snapshot left by a departed canvas: a thumbnail
    /// arriving after the canvas left is the render that snapshot was waiting for.
    var thumbnail: UIImage? {
        get { thumbnailView.image }
        set {
            thumbnailView.image = newValue
            removeInkPlaceholder()
        }
    }

    func removeInkPlaceholder() {
        guard let placeholder = inkPlaceholder else { return }
        placeholder.view.removeFromSuperview()
        inkPlaceholder = nil
        updateThumbnailMask()
    }

    /// How long the live canvas takes to replace the thumbnail underneath it.
    /// Short enough not to feel like an animation, long enough that the swap reads
    /// as the page sharpening rather than as a different page being dealt onto the
    /// stack.
    private static let canvasFadeDuration: TimeInterval = 0.18

    /// Hands this tile a live canvas, into the same container as everything else.
    ///
    /// The grid stays — it is the page's only grid, and the canvas is transparent
    /// ink over it. The thumbnail is a render of this very page's ink, so it cannot
    /// misalign with what replaces it, and it stays underneath while the canvas
    /// fades in over it. That crossfade is the point. A canvas appearing in
    /// one frame — typically right as a pinch commits, when the page is also
    /// changing size — is a hard visual cut, and it lands exactly where the user's
    /// attention already is.
    func attach(_ canvas: PageCanvasController, animated: Bool) {
        removeInkPlaceholder()
        self.canvas = canvas
        canvas.view.alpha = 1
        pageContainer.addSubview(canvas.view)

        isFadingInCanvas = animated && thumbnailView.image != nil
        // Placed now, not at the next layout pass: `configure(...)` follows straight
        // away and fits the page to whatever frame the canvas has at that moment.
        setNeedsLayout()
        layoutIfNeeded()
        guard isFadingInCanvas else { return }

        canvas.view.alpha = 0
        UIView.animate(
            withDuration: Self.canvasFadeDuration,
            delay: 0,
            // `.allowUserInteraction` so a pencil stroke started during the fade
            // still lands on the canvas; `.beginFromCurrentState` so a tile that is
            // recycled mid-fade picks up where it is instead of snapping.
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: { canvas.view.alpha = 1 },
            completion: { [weak self] _ in
                // Only if this tile still holds the canvas the fade was for —
                // otherwise a tile whose canvas was reclaimed mid-fade would end up
                // showing neither.
                guard let self, self.canvas === canvas else { return }
                self.isFadingInCanvas = false
                self.updateThumbnailMask()
            })
    }

    /// `keepingInk` leaves a snapshot of the canvas in its place until the next
    /// thumbnail arrives — for a canvas whose ink the thumbnail doesn't have yet.
    @discardableResult
    func detachCanvas(keepingInk: Bool = false) -> PageCanvasController? {
        let detached = canvas
        if keepingInk, let detached, !isFadingInCanvas,
            let snapshot = detached.view.snapshotView(afterScreenUpdates: false)
        {
            inkPlaceholder?.view.removeFromSuperview()
            snapshot.isUserInteractionEnabled = false
            snapshot.frame = detached.view.frame
            pageContainer.insertSubview(snapshot, aboveSubview: thumbnailView)
            inkPlaceholder = (snapshot, detached.visiblePageRect)
        }
        detached?.view.layer.removeAllAnimations()
        detached?.view.alpha = 1
        detached?.view.removeFromSuperview()
        canvas = nil
        isFadingInCanvas = false
        updateThumbnailMask()
        return detached
    }
}
