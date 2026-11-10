//
//  ToolDiskView.swift
//  kisaca
//
//  The tool disk: a half-disc of glass rising from the bottom edge of the notebook,
//  opened by a two-finger sideways swipe anywhere on the page. Tools on the outer
//  ring, colours on the middle one, widths between undo and redo at the hub — the
//  same controls as the rail (`ToolControls`), so it's the way to switch tools while
//  the rail is hidden.
//
//  Covers the whole notebook while open: a touch outside the disc (finger or Pencil)
//  closes it and does nothing else, so a stray Pencil touch can't leave a mark.
//  Picking a tool closes it; colours and widths leave it open for a second choice.
//

import UIKit

@MainActor
final class ToolDiskView: UIView {
    let controls: ToolControls
    var onDismiss: () -> Void = {}
    /// After every layout: the tool pictures' angles changed, so the notebook re-shows
    /// the toolbox (which slides the tool in hand out along its angle).
    var onLayout: () -> Void = {}

    private let disc = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private var outer: [UIView] = []
    private var inner: [UIView] = []
    private var hub: [UIView] = []

    init(send: @escaping (NotebookToolAction) -> Void) {
        var dismiss: () -> Void = {}
        controls = ToolControls(size: 46) { action in
            send(action)
            if case .select = action { dismiss() }
        }
        super.init(frame: .zero)
        dismiss = { [weak self] in self?.dismiss(after: 0.12) }

        backgroundColor = UIColor.black.withAlphaComponent(0.06)
        // Dark, like the sidebar.
        overrideUserInterfaceStyle = .dark
        disc.effect = {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = UIColor.black.withAlphaComponent(0.75)
            return glass
        }()
        addSubview(disc)

        outer = NotebookToolKind.allCases.compactMap { controls.toolButtons[$0] }
            + [controls.rulerButton, controls.insertButton]
        inner = controls.swatches + [controls.colorWell]
        hub = [controls.undoButton] + controls.widthButtons + [controls.redoButton]
        for view in outer + inner + hub {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.removeConstraints(view.constraints)
            disc.contentView.addSubview(view)
        }

        let outside = UITapGestureRecognizer(target: self, action: #selector(tappedOutside(_:)))
        outside.allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        addGestureRecognizer(outside)
        isAccessibilityElement = false
        accessibilityViewIsModal = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    /// The disc's radius: as large as fits the notebook, up to 300 pt.
    private var radius: CGFloat {
        min(300, (bounds.width - 24) / 2, bounds.height * 0.45)
    }

    /// The disc's centre sits a little above the bottom edge, so a bit more than half
    /// of it shows above the home indicator.
    private var hubCenter: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.maxY - safeAreaInsets.bottom * 0.5 - 8)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = radius
        let c = hubCenter
        disc.frame = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        disc.cornerConfiguration = .capsule()
        let local = CGPoint(x: r, y: r)
        place(outer, radius: r - 42, center: local, from: 165, to: 15)
        place(inner, radius: r - 112, center: local, from: 160, to: 20)
        place(hub, radius: max(r - 182, 60), center: local, from: 155, to: 25)
        onLayout()
    }

    /// Spreads `views` evenly along an arc, angles in degrees, 0° = right, 90° = up.
    private func place(_ views: [UIView], radius: CGFloat, center: CGPoint, from: CGFloat, to: CGFloat) {
        guard !views.isEmpty else { return }
        let step = views.count > 1 ? (to - from) / CGFloat(views.count - 1) : 0
        for (index, view) in views.enumerated() {
            let angle = (from + step * CGFloat(index)) * .pi / 180
            let size = controls.size(of: view)
            view.bounds = CGRect(origin: .zero, size: size)
            view.center = CGPoint(
                x: center.x + radius * cos(angle), y: center.y - radius * sin(angle))
            // Tool pictures point outwards, nib to the rim — like pens in a tray.
            if let kind = controls.toolButtons.first(where: { $0.value === view })?.key {
                controls.setRestingTransform(CGAffineTransform(rotationAngle: -angle), for: kind)
            }
        }
    }

    // MARK: - Showing

    func present() {
        alpha = 0
        layoutIfNeeded()
        disc.transform = CGAffineTransform(translationX: 0, y: radius * 0.6).scaledBy(x: 0.6, y: 0.6)
        UIView.animate(
            withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0
        ) {
            self.alpha = 1
            self.disc.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: controls.toolButtons[.pen])
    }

    func dismiss(after delay: TimeInterval = 0) {
        UIView.animate(withDuration: 0.2, delay: delay, options: [.curveEaseIn]) {
            self.alpha = 0
            self.disc.transform = CGAffineTransform(translationX: 0, y: self.radius * 0.4)
                .scaledBy(x: 0.8, y: 0.8)
        } completion: { _ in
            self.removeFromSuperview()
            self.onDismiss()
        }
    }

    @objc private func tappedOutside(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        let c = hubCenter
        if hypot(point.x - c.x, point.y - c.y) > radius { dismiss() }
    }

    /// Touches outside the disc that aren't taps (a Pencil stroke, a drag) close it too.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let point = touches.first?.location(in: self) else { return }
        let c = hubCenter
        if hypot(point.x - c.x, point.y - c.y) > radius { dismiss() }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }
}
