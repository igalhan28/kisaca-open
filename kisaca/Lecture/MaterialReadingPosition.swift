//
//  MaterialReadingPosition.swift
//  kisaca
//
//  Where the student left off in each material, so opening it again — beside the
//  notebook or full screen from the Materials list — picks up at that page instead of
//  the first one.
//
//  Kept per device in `UserDefaults` (`AppPreferences.Key.materialReadingPositions`),
//  keyed by material ID, not in the `.kisaca` document: scrolling a script is not an
//  edit, and writing it into the lecture file would mean a save (and an iCloud upload,
//  and a chance of a version conflict) on every page turn.
//
//  Only PDFs have a position: Quick Look, which shows every other kind of file, offers
//  no way to read or set one.
//

import PDFKit
import UIKit

struct MaterialReadingPosition: Codable, Equatable {
    var pageIndex: Int
    /// The point at the top-left of the view, in the page's own (PDF) coordinates.
    var x: Double
    var y: Double
    /// Zoom relative to fit-to-width, so the same position fits a pane and a full screen.
    var zoom: Double

    private static var key: String { AppPreferences.Key.materialReadingPositions }

    private static func all() -> [String: MaterialReadingPosition] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: MaterialReadingPosition].self, from: data)) ?? [:]
    }

    static func saved(for materialID: UUID) -> MaterialReadingPosition? {
        all()[materialID.uuidString]
    }

    static func save(_ position: MaterialReadingPosition, for materialID: UUID) {
        var positions = all()
        guard positions[materialID.uuidString] != position else { return }
        positions[materialID.uuidString] = position
        store(positions)
    }

    /// Called when the material is deleted from its lecture.
    static func forget(_ materialID: UUID) {
        var positions = all()
        guard positions.removeValue(forKey: materialID.uuidString) != nil else { return }
        store(positions)
    }

    private static func store(_ positions: [String: MaterialReadingPosition]) {
        if let data = try? JSONEncoder().encode(positions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// A `PDFView` for one material that opens where it was last left and remembers where it
/// is left now: on every page change, when it leaves the screen, and when the app leaves
/// the active state (which is also when it may be killed).
final class ResumingPDFView: PDFView {
    private let materialID: UUID
    private var hasRestored = false

    init(document: PDFDocument, materialID: UUID) {
        self.materialID = materialID
        super.init(frame: .zero)
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        autoScales = true
        self.document = document

        NotificationCenter.default.addObserver(
            self, selector: #selector(savePosition), name: .PDFViewPageChanged, object: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(savePosition),
            name: UIScene.willDeactivateNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Restores on the first layout with a real size: before that, `PDFView` has no
    /// fit scale to measure zoom against and ignores `go(to:)`.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !hasRestored, bounds.width > 0, bounds.height > 0 else { return }
        hasRestored = true
        restorePosition()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { savePosition() }
        super.willMove(toWindow: newWindow)
    }

    private func restorePosition() {
        guard let saved = MaterialReadingPosition.saved(for: materialID),
            let document, saved.pageIndex < document.pageCount,
            let page = document.page(at: saved.pageIndex)
        else { return }
        // Zoomed-in reading comes back zoomed in; at fit width, `autoScales` stays on so
        // the page keeps fitting when the pane is resized.
        if abs(saved.zoom - 1) > 0.01 {
            autoScales = false
            scaleFactor = scaleFactorForSizeToFit * saved.zoom
        }
        go(to: PDFDestination(page: page, at: CGPoint(x: saved.x, y: saved.y)))
    }

    @objc private func savePosition() {
        // Until restored, the view is still on page one and would overwrite the real spot.
        guard hasRestored, let document, let destination = currentDestination,
            let page = destination.page
        else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        let fit = scaleFactorForSizeToFit
        MaterialReadingPosition.save(
            MaterialReadingPosition(
                pageIndex: index, x: destination.point.x, y: destination.point.y,
                zoom: fit > 0 ? scaleFactor / fit : 1),
            for: materialID)
    }
}
