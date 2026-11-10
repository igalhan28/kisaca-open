//
//  ToolWheelView.swift
//  kisaca
//
//  The tool wheel: a quick way back to the tools you were just using, turned like an
//  iPod's click wheel. Two fingers swiped sideways anywhere on the page bring it up
//  with the recently used tool + colour + width combinations around its rim
//  (`NotebookToolbox.wheelCombos`) — the one in hand at the top, under the pointer.
//  Keep swiping and the wheel turns with your fingers, one combination per notch, with
//  a tick you can feel at each; the hub names the one under the pointer. Lift your
//  fingers to take it up. Swiping back to where you started changes nothing.
//
//  Swiping left turns the wheel anticlockwise, bringing up the combination to the
//  right of the pointer — the one you used most recently before this one. So one
//  short swipe left goes back and forth between your last two tools.
//
//  It only shows what the gesture does: it never takes touches itself, so it can't
//  get in the way of the Pencil. Everything is also in the sidebar.
//

import UIKit

@MainActor
final class ToolWheelView: UIView {
    /// Finger travel for one notch.
    static let pointsPerNotch: CGFloat = 64
    private static let hubIconScale: CGFloat = 1.5

    private let combos: [ToolCombo]
    private let disc = UIVisualEffectView()
    private let pointer = UIImageView()
    private let slotRing = UIView()
    private var chips: [ComboChip] = []
    private let hubIcon = UIImageView()
    private let hubTitle = UILabel()
    private let hubDetail = UILabel()
    private let hubStack = UIStackView()
    private let haptics = UISelectionFeedbackGenerator()

    /// How far the wheel has turned, in notches: 1 brings `combos[1]` to the pointer.
    private var rotation: CGFloat = 0
    private var shownIndex = 0

    init(combos: [ToolCombo]) {
        self.combos = combos
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        overrideUserInterfaceStyle = .dark
        backgroundColor = UIColor.black.withAlphaComponent(0.08)

        let glass = UIGlassEffect(style: .regular)
        glass.tintColor = UIColor.black.withAlphaComponent(0.78)
        disc.effect = glass
        addSubview(disc)

        // The fixed slot at the top, where the pointer is: a ring the chips turn into.
        slotRing.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        slotRing.layer.borderWidth = 2
        disc.contentView.addSubview(slotRing)

        for combo in combos {
            let chip = ComboChip(combo: combo)
            chips.append(chip)
            disc.contentView.addSubview(chip)
        }

        pointer.image = UIImage(systemName: "arrowtriangle.down.fill")
        pointer.tintColor = .white
        pointer.contentMode = .scaleAspectFit
        disc.contentView.addSubview(pointer)

        hubIcon.contentMode = .scaleAspectFit
        hubIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hubIcon.widthAnchor.constraint(equalToConstant: ToolIcons.size.width * Self.hubIconScale),
            hubIcon.heightAnchor.constraint(equalToConstant: ToolIcons.size.height * Self.hubIconScale),
        ])
        hubTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        hubTitle.textColor = .white
        hubTitle.textAlignment = .center
        hubDetail.font = .systemFont(ofSize: 13, weight: .regular)
        hubDetail.textColor = UIColor.white.withAlphaComponent(0.7)
        hubDetail.textAlignment = .center
        hubDetail.numberOfLines = 2
        hubStack.axis = .vertical
        hubStack.alignment = .center
        hubStack.spacing = 6
        [hubIcon, hubTitle, hubDetail].forEach(hubStack.addArrangedSubview)
        hubStack.setCustomSpacing(10, after: hubIcon)
        disc.contentView.addSubview(hubStack)

        isAccessibilityElement = false
        showSelection(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Geometry

    /// Never so small that eight chips crowd each other: beside a wide material pane
    /// the wheel may reach past the notebook over it.
    private var radius: CGFloat {
        min(190, max(160, min(bounds.width, bounds.height) * 0.36))
    }

    /// The chips' circle; the room above the top slot holds the pointer.
    private var ringRadius: CGFloat { radius - 58 }

    private var step: CGFloat { 2 * .pi / CGFloat(max(combos.count, 1)) }

    /// The combination under the pointer.
    private var selectedIndex: Int {
        let count = combos.count
        guard count > 0 else { return 0 }
        let notch = Int(rotation.rounded())
        return ((notch % count) + count) % count
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = radius
        disc.bounds = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
        disc.center = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerConfiguration = .capsule()

        let chipSide = ComboChip.side
        let slot = chipSide + 12
        slotRing.bounds = CGRect(x: 0, y: 0, width: slot, height: slot)
        slotRing.center = CGPoint(x: r, y: r - ringRadius)
        slotRing.layer.cornerRadius = slot / 2
        pointer.frame = CGRect(x: r - 8, y: r - ringRadius - slot / 2 - 15, width: 16, height: 13)

        let hubWidth = max(2 * (ringRadius - chipSide / 2 - 10), 90)
        let hubHeight = hubStack.systemLayoutSizeFitting(
            CGSize(width: hubWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        hubStack.bounds = CGRect(x: 0, y: 0, width: hubWidth, height: hubHeight)
        hubStack.center = CGPoint(x: r, y: r)
        placeChips()
    }

    /// Puts each chip on the rim at its angle for the current rotation: the selected
    /// slot at the top (−90°), the rest clockwise in order.
    private func placeChips() {
        let r = radius
        for (index, chip) in chips.enumerated() {
            let angle = -.pi / 2 + (CGFloat(index) - rotation) * step
            chip.bounds = CGRect(x: 0, y: 0, width: ComboChip.side, height: ComboChip.side)
            chip.center = CGPoint(x: r + ringRadius * cos(angle), y: r + ringRadius * sin(angle))
        }
    }

    // MARK: - Driving it

    func present() {
        haptics.prepare()
        alpha = 0
        layoutIfNeeded()
        disc.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
        UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
            self.alpha = 1
            self.disc.transform = .identity
        }
    }

    /// Turns the wheel with the fingers: `translation` is how far they have moved
    /// sideways since the swipe began. Left is positive rotation.
    func turn(toTranslation translation: CGFloat) {
        rotation = -translation / Self.pointsPerNotch
        placeChips()
        if selectedIndex != shownIndex {
            haptics.selectionChanged()
            haptics.prepare()
            showSelection(animated: true)
        }
    }

    /// The fingers lifted: settles on the nearest notch and goes away. Returns the
    /// combination under the pointer.
    func commit() -> ToolCombo? {
        guard !combos.isEmpty else {
            dismiss(after: 0)
            return nil
        }
        rotation = rotation.rounded()
        UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut]) {
            self.placeChips()
        }
        let combo = combos[selectedIndex]
        UIAccessibility.post(notification: .announcement, argument: combo.title)
        dismiss(after: 0.22)
        return combo
    }

    /// The swipe was called off: goes away without choosing.
    func cancel() { dismiss(after: 0) }

    private func dismiss(after delay: TimeInterval) {
        UIView.animate(withDuration: 0.2, delay: delay, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.alpha = 0
            self.disc.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        } completion: { _ in
            self.removeFromSuperview()
        }
    }

    /// The hub names the combination under the pointer; its chip stands out.
    private func showSelection(animated: Bool) {
        shownIndex = selectedIndex
        guard combos.indices.contains(shownIndex) else { return }
        let combo = combos[shownIndex]
        hubIcon.image = ToolIcons.image(
            for: combo.kind, ink: combo.color ?? .black, erasesPixels: combo.erasesPixels,
            magnification: Self.hubIconScale)
        let parts = combo.title.components(separatedBy: ", ")
        hubTitle.text = parts.first
        hubDetail.text = parts.dropFirst().joined(separator: " · ")
        hubDetail.isHidden = parts.count < 2
        let update = {
            for (index, chip) in self.chips.enumerated() {
                let selected = index == self.shownIndex
                chip.transform = selected ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
                chip.alpha = selected ? 1 : 0.62
            }
        }
        if animated {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: update)
        } else {
            update()
        }
        setNeedsLayout()
    }
}

// MARK: - Chip

/// One combination on the rim: the tool's picture in its ink, and a stroke showing
/// its width in that ink.
@MainActor
private final class ComboChip: UIView {
    static let side: CGFloat = 70

    init(combo: ToolCombo) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.1)
        layer.cornerRadius = Self.side / 2

        let icon = UIImageView(image: ToolIcons.image(
            for: combo.kind, ink: combo.color ?? .black, erasesPixels: combo.erasesPixels))
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(
            x: (Self.side - ToolIcons.size.width) / 2, y: Self.side / 2 - ToolIcons.size.height + 2,
            width: ToolIcons.size.width, height: ToolIcons.size.height)
        addSubview(icon)

        if combo.kind != .lasso {
            let thickness = [1.5, 3, 5.5][min(max(combo.widthLevel, 0), 2)] as CGFloat
            let stroke = UIView(frame: CGRect(
                x: Self.side / 2 - 14, y: Self.side / 2 + 9 - thickness / 2, width: 28, height: thickness))
            let ink = combo.color ?? .white
            // Black ink on the dark glass needs an edge to be seen.
            stroke.backgroundColor = ink
            stroke.layer.cornerRadius = thickness / 2
            stroke.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
            stroke.layer.borderWidth = ink.isClose(to: NotebookToolbox.palette[0]) ? 1 : 0
            addSubview(stroke)
        }
        isAccessibilityElement = true
        accessibilityLabel = combo.title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - Gesture

/// Two fingers moving sideways together — not a pinch, not a vertical scroll. Begins
/// once both fingers have moved the same way far enough, reports how far they've
/// moved together (`translation`), and ends when either lifts. Watches only: other
/// recognisers keep the touches (the delegate lets them run alongside).
@MainActor
final class TwoFingerSwipeRecognizer: UIGestureRecognizer {
    /// Sideways movement of the fingers' midpoint since they came down.
    private(set) var translation: CGFloat = 0

    private var starts: [ObjectIdentifier: CGPoint] = [:]
    private var touches: [ObjectIdentifier: UITouch] = [:]
    private var startSpread: CGFloat = 0
    private var startMid: CGPoint = .zero

    /// Each finger must move this far sideways before it counts as a swipe.
    private let threshold: CGFloat = 14

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            self.touches[id] = touch
            starts[id] = touch.location(in: view)
        }
        guard self.touches.count <= 2 else {
            // A third finger: not this gesture.
            state = state == .possible ? .failed : .cancelled
            return
        }
        if self.touches.count == 2 {
            // Measure from when the second finger lands.
            for (id, touch) in self.touches { starts[id] = touch.location(in: view) }
            let points = Array(starts.values)
            startSpread = hypot(points[0].x - points[1].x, points[0].y - points[1].y)
            startMid = midpoint(points)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        let current = self.touches.mapValues { $0.location(in: view) }
        switch state {
        case .possible:
            if current.count == 1, let (id, point) = current.first, let start = starts[id],
                hypot(point.x - start.x, point.y - start.y) > 30
            {
                // One finger already dragging: a scroll, not this.
                state = .failed
                return
            }
            guard current.count == 2 else { return }
            let deltas = current.map { id, point in
                CGPoint(x: point.x - (starts[id]?.x ?? point.x), y: point.y - (starts[id]?.y ?? point.y))
            }
            let points = Array(current.values)
            let spread = hypot(points[0].x - points[1].x, points[0].y - points[1].y)
            if abs(spread - startSpread) > 36 {
                state = .failed  // A pinch.
                return
            }
            if deltas.contains(where: { abs($0.y) > 24 && abs($0.y) > abs($0.x) }) {
                state = .failed  // A vertical scroll.
                return
            }
            let sideways = deltas.allSatisfy { abs($0.x) > threshold && abs($0.x) > 1.4 * abs($0.y) }
            let together = (deltas[0].x > 0) == (deltas[1].x > 0)
            if sideways, together {
                translation = midpoint(points).x - startMid.x
                state = .began
            }
        case .began, .changed:
            guard current.count == 2 else { return }
            translation = midpoint(Array(current.values)).x - startMid.x
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches, ended: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches, ended: false)
    }

    private func lift(_ lifted: Set<UITouch>, ended: Bool) {
        for touch in lifted {
            touches[ObjectIdentifier(touch)] = nil
            starts[ObjectIdentifier(touch)] = nil
        }
        switch state {
        case .began, .changed:
            // The first finger up ends it — that's the "let go".
            state = ended ? .ended : .cancelled
        case .possible:
            if touches.isEmpty || !ended { state = .failed }
        default:
            break
        }
    }

    override func reset() {
        super.reset()
        touches = [:]
        starts = [:]
        translation = 0
        startSpread = 0
        startMid = .zero
    }

    private func midpoint(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}
