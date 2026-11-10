//
//  NotebookCoordinator.swift
//  kisaca
//
//  Observable state between the notebook screen's bar (`NotebookViewController`) and
//  the canvas (`NotebookPagerViewController`). The screen observes `currentPageIndex` /
//  `totalPages` and the rest for its bar (UIKit tracks the reads in `updateProperties`);
//  bar actions call the methods here, which just forward to the pager.
//  Things the screen has to present (the share sheet, the selected-text alert) come
//  through callbacks rather than observed flags.
//
//  Also owns the autosave timer: periodically flushes the page on screen, so a page
//  the user sits and writes on for a long time without turning still gets saved
//  regularly. Every *other* page is already flushed the moment it is turned away from
//  (see `NotebookPagerViewController`).
//

import CoreGraphics
import Foundation
import Observation
import PaperKit

@Observable
@MainActor
final class NotebookCoordinator {

    // MARK: - State (observed by NotebookViewController)

    var currentPageIndex: Int = 0
    var totalPages: Int = 1
    /// False when the current page is the only one of its session — that one stays.
    var canDeleteCurrentPage: Bool = false
    /// Title of the session the current page belongs to ("W3 · Mon") — changes while
    /// scrolling a whole-section notebook, fixed for a single session.
    var currentSessionTitle: String?
    /// The session the current page belongs to — where a material added from the
    /// notebook is filed (its week).
    var currentSessionID: UUID?

    /// True while the PDF is being generated (drives the loading overlay).
    var isExporting: Bool = false

    // MARK: - Presenting (set by NotebookViewController)

    /// A generated PDF, ready for the share sheet.
    @ObservationIgnored var onPDFReady: ((URL) -> Void)?

    /// The "Selected Text" alert's message.
    @ObservationIgnored var onSelectedText: ((String) -> Void)?

    // MARK: - Internal link to UIKit

    /// Set by `NotebookViewController`.
    @ObservationIgnored weak var pager: NotebookPagerViewController?

    /// Set by `NotebookViewController`.
    @ObservationIgnored var pageRepository: PageRepository?

    // MARK: - Autosave timer

    @ObservationIgnored private var autosaveTimer: Timer?

    /// Starts the periodic flush. Called when the notebook screen appears.
    func startAutosaveTimer(interval: TimeInterval = 8) {
        stopAutosaveTimer()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pager?.autosaveActivePage() }
        }
    }

    /// Stops the periodic flush. Called when the notebook screen disappears (paired with
    /// an explicit `flushActivePage()` there, and on leaving the active state).
    func stopAutosaveTimer() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
    }

    func flushActivePage() {
        pager?.flushActivePage()
    }

    // MARK: - Actions (called by the notebook screen's bar)

    func addPage() {
        pager?.addPage()
    }

    func deleteCurrentPage() {
        pager?.deleteCurrentPage()
    }

    /// Goes straight to the page at `index`, without a turn.
    func showPage(at index: Int) {
        pager?.showPage(at: index)
    }

    /// See `NotebookPagerViewController.reclaimFocus()`.
    func reclaimFocus() {
        pager?.reclaimFocus()
    }

    func clear() {
        pager?.clearActivePage()
    }

    func undo() {
        pager?.undoActivePage()
    }

    func redo() {
        pager?.redoActivePage()
    }

    // MARK: - Selected text

    /// Reads the text out of whatever the user has selected on the active page and
    /// shows it in an alert.
    ///
    /// Stands in for the eventual "Search the Web for Selection" action. PaperKit's own
    /// long-press menu (the one with "Copy as Text") is closed — the framework exposes
    /// no hook for adding an item to it — so any action on the selection has to live on
    /// our own toolbar and read `PaperMarkupViewController.selectedMarkup` itself.
    ///
    /// Whether `indexableContent` covers *handwriting* (as opposed to only text boxes)
    /// is not documented and can't be checked in the simulator without a Pencil, so the
    /// alert reports which case it hit rather than silently showing nothing.
    func showSelectedText() {
        guard let selection = pager?.activeSelection else {
            present("Nothing is selected on this page.")
            return
        }

        let frame = selection.contentsRenderFrame

        Task { @MainActor in
            switch await selection.indexableContent {
            case .none:
                present(Self.noTextMessage(reason: "indexableContent was nil", frame: frame))
            case .some(let text) where text.isEmpty:
                present(Self.noTextMessage(reason: "indexableContent was empty", frame: frame))
            case .some(let text):
                present(text)
            }
        }
    }

    private func present(_ message: String) {
        onSelectedText?(message)
    }

    private static func noTextMessage(reason: String, frame: CGRect) -> String {
        "The selection has no extractable text.\n(\(reason) — selection frame \(describe(frame)))"
    }

    private static func describe(_ rect: CGRect) -> String {
        guard !rect.isNull else { return "null" }
        return String(
            format: "%.0f×%.0f at (%.0f, %.0f)",
            rect.width, rect.height, rect.minX, rect.minY)
    }

    // MARK: - PDF Export

    /// Triggers async PDF generation; hands the file to `onPDFReady` when done.
    /// - Parameters:
    ///   - pageIndices: pages to include, in order. `nil` exports every page (used by
    ///     "Export All"); a subset is used by the "Select Pages" flow (`PDFExportViewController`).
    ///   - fileName: desired PDF name (without extension), e.g. "Calculus II - Exercise
    ///     Sessions - 29.10.2026". `nil` falls back to a timestamped default.
    func generatePDF(pageIndices: [Int]? = nil, fileName: String? = nil) {
        guard let pager, let pageRepository else { return }
        guard !isExporting else { return }  // Prevent double-tap.

        // Capture live markup before going async (on the main actor).
        pager.flushActivePage()
        let activeMarkup = pager.activeMarkup
        let activeIndex = currentPageIndex

        isExporting = true

        Task { @MainActor in
            let url = await PDFExporter.generatePDF(
                from: pageRepository,
                activeMarkup: activeMarkup,
                activeIndex: activeIndex,
                pageIndices: pageIndices,
                fileName: fileName
            )
            isExporting = false
            onPDFReady?(url)
        }
    }
}
