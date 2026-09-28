//
//  NotebookScreen.swift
//  kisaca
//
//  The actual note-taking screen: hosts the notebook canvas (NotebookHostView) for
//  one `LectureSession` — or a whole section read as one notebook — plus the
//  surrounding SwiftUI chrome (page counter, undo, clear, export). Sits one level
//  below Section in the Lecture → Section → Session navigation.
//
//  Course material can open beside the notebook (the split button): see
//  `MaterialPane` and "Material pane" below.
//
//  Owns the autosave timer's lifecycle (start on appear, flush + stop on disappear
//  or backgrounding) — see NotebookCoordinator.swift and
//  docs/document-format.md → "Autosave design".
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What a `NotebookScreen` shows — the navigation value pushed from a section's list.
nonisolated struct NotebookRoute: Hashable {
    var scope: PageRepository.Scope
    /// For a whole-section notebook: the session to open at.
    var initialSessionID: UUID?
}

struct NotebookScreen: View {
    @ObservedObject var document: LectureDocument
    let route: NotebookRoute

    @State private var coordinator = NotebookCoordinator()
    @State private var showingExportOptions = false
    @State private var showingDeletePageConfirmation = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // Material pane. Side and width are device preferences (AppPreferences) — kept across
    // launches, the same for every lecture; whether it is open and what it shows are not.
    @AppStorage(AppPreferences.Key.materialPaneSide)
    private var paneSideRaw = MaterialPaneSide.default.rawValue
    @AppStorage(AppPreferences.Key.materialPaneFraction)
    private var paneFraction = AppPreferences.defaultMaterialPaneFraction
    @State private var showingMaterialPane = false
    @State private var paneMaterialID: UUID?
    @State private var showingMaterialImporter = false
    @State private var materialImportError: String?
    /// The divider's position while it is being dragged; applied on release.
    @State private var dragFraction: Double?

    /// "W3 · Mon" for one session; "Lectures · W3 · Mon" for a whole section, where
    /// the second half follows the page being read.
    private var title: String {
        switch route.scope {
        case .session(let id):
            return document.manifest.sessions.first { $0.id == id }
                .map { document.manifest.title(for: $0) } ?? "Notebook"
        case .section(let id):
            let name = document.manifest.section(withID: id)?.name ?? "Notebook"
            return [name, coordinator.currentSessionTitle].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var body: some View {
        ZStack {
            splitLayout

            if coordinator.isExporting {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                    Text("Exporting PDF…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                .padding(28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Button {
                    toggleMaterialPane()
                } label: {
                    Label(
                        showingMaterialPane ? "Hide Material" : "Open Material Beside Notes",
                        systemImage: "rectangle.split.2x1")
                }
                .symbolVariant(showingMaterialPane ? .fill : .none)

                // Quick add: files land under this session's week and open beside the notes.
                Button {
                    showingMaterialImporter = true
                } label: {
                    Label("Add Material", systemImage: "paperclip.badge.plus")
                }

                // Adds after the current page; deletes the current page. Moving between
                // pages is scrolling — there are no previous/next buttons.
                Button {
                    coordinator.addPage()
                } label: {
                    Label("Add Page", systemImage: "plus.rectangle.portrait")
                }

                // Compact: next to a long title ("Lectures · W12 · Thu") a "Page 5 of 23"
                // label gets truncated to "Pag…".
                Text("\(coordinator.currentPageIndex + 1) / \(coordinator.totalPages)")
                    .font(.caption)
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityLabel(
                        "Page \(coordinator.currentPageIndex + 1) of \(coordinator.totalPages)")

                Button {
                    showingDeletePageConfirmation = true
                } label: {
                    Label("Delete Page", systemImage: "minus.rectangle.portrait")
                }
                .disabled(!coordinator.canDeleteCurrentPage)
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Stands in for "Search the Web for Selection". It can't live in
                // PaperKit's own long-press menu next to "Copy as Text" — that menu
                // takes no custom items — so it sits here and reads the selection
                // off the canvas itself. See `NotebookCoordinator.showSelectedText()`.
                Button {
                    coordinator.showSelectedText()
                } label: {
                    Label("Selected Text", systemImage: "text.magnifyingglass")
                }

                Button {
                    showingExportOptions = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Button {
                    coordinator.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }

                Menu {
                    Button("Clear Page", systemImage: "trash", role: .destructive) {
                        coordinator.clear()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $coordinator.isShareSheetPresented) {
            if let url = coordinator.pdfURL {
                ShareSheet(activityItems: [url])
                    .presentationDetents([.medium, .large])
            }
        }
        // No room for two panes side by side (iPhone, narrow Split View): the material
        // opens as a sheet over the notebook instead.
        .sheet(isPresented: compactPaneBinding) {
            MaterialPane(
                document: document, materialID: $paneMaterialID,
                onClose: { showingMaterialPane = false },
                currentWeek: currentWeek, onAdd: { showingMaterialImporter = true })
        }
        .fileImporter(
            isPresented: $showingMaterialImporter, allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): addMaterials(from: urls)
            case .failure(let error): materialImportError = error.localizedDescription
            }
        }
        .alert(
            "Couldn't Add File",
            isPresented: Binding(
                get: { materialImportError != nil }, set: { if !$0 { materialImportError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(materialImportError ?? "")
        }
        .sheet(isPresented: $showingExportOptions) {
            PDFExportSheet(document: document, notebookTitle: title, coordinator: coordinator)
        }
        .alert(
            "Delete Page \(coordinator.currentPageIndex + 1)?",
            isPresented: $showingDeletePageConfirmation
        ) {
            Button("Delete", role: .destructive) { coordinator.deleteCurrentPage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The page and everything written on it will be permanently deleted.")
        }
        .alert("Selected Text", isPresented: $coordinator.isSelectedTextAlertPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.selectedTextMessage ?? "")
        }
        .onAppear {
            coordinator.startAutosaveTimer()
        }
        .onDisappear {
            coordinator.stopAutosaveTimer()
            coordinator.flushActivePage()
        }
        .onChange(of: showingMaterialPane) {
            // Opening or closing the pane re-lays out the notebook and can move first
            // responder; give the tool picker back once that has settled.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                coordinator.reclaimToolPicker()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                coordinator.flushActivePage()
            }
        }
    }
}

// MARK: - Material pane

extension NotebookScreen {
    private var paneSide: MaterialPaneSide {
        MaterialPaneSide(rawValue: paneSideRaw) ?? .default
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

    private var paneIsInline: Bool { showingMaterialPane && !isCompact }

    private var compactPaneBinding: Binding<Bool> {
        Binding(
            get: { showingMaterialPane && isCompact },
            set: { if !$0 { showingMaterialPane = false } })
    }

    private func clampedFraction(_ value: Double) -> Double {
        let range = AppPreferences.materialPaneFractionRange
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Notebook and material side by side. The notebook keeps the same place in the view
    /// tree whether the pane is open or not — the pane is an optional sibling on one side
    /// or the other — so opening, closing or moving the pane never rebuilds the canvas
    /// (which would drop its scroll position, zoom and any unsaved ink).
    private var splitLayout: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            let paneWidth = total * clampedFraction(paneFraction)
            HStack(spacing: 0) {
                if paneIsInline && paneSide == .leading {
                    pane.frame(width: paneWidth)
                    divider(total: total)
                }
                NotebookHostView(
                    document: document, scope: route.scope,
                    initialSessionID: route.initialSessionID, coordinator: coordinator)
                    .ignoresSafeArea()
                if paneIsInline && paneSide == .trailing {
                    divider(total: total)
                    pane.frame(width: paneWidth)
                }
            }
            .overlay(alignment: .topLeading) {
                // Where the divider will land. The panes resize only on release: resizing
                // the notebook re-lays out and re-renders PaperKit, too heavy for every
                // frame of a drag.
                if let dragFraction {
                    let x = paneSide == .leading ? dragFraction * total : (1 - dragFraction) * total
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .frame(maxHeight: .infinity)
                        .offset(x: x - 1.5)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: Self.splitSpace)
        }
    }

    private static let splitSpace = "notebookSplit"

    private var pane: some View {
        MaterialPane(
            document: document, materialID: $paneMaterialID,
            onClose: { withAnimation(.snappy) { showingMaterialPane = false } },
            currentWeek: currentWeek, onAdd: { showingMaterialImporter = true },
            onContentShown: { coordinator.reclaimToolPicker() })
    }

    private func divider(total: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)
            Capsule()
                .fill(Color(.tertiaryLabel))
                .frame(width: 5, height: 44)
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .ignoresSafeArea(edges: .bottom)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.splitSpace))
                .onChanged { value in
                    guard total > 0 else { return }
                    let x = value.location.x / total
                    dragFraction = clampedFraction(paneSide == .leading ? x : 1 - x)
                }
                .onEnded { _ in
                    if let dragFraction { paneFraction = dragFraction }
                    dragFraction = nil
                }
        )
        .accessibilityLabel("Resize Material")
    }

    /// Semester week of the session being written (follows the page in a whole-section
    /// notebook); `nil` without a semester.
    private var currentWeek: Int? {
        let id: UUID?
        switch route.scope {
        case .session(let sessionID): id = sessionID
        case .section: id = coordinator.currentSessionID ?? route.initialSessionID
        }
        return document.manifest.sessions.first { $0.id == id }
            .flatMap { document.manifest.week(of: $0) }
    }

    /// Files the picked files under the current week and shows the first beside the notes.
    private func addMaterials(from urls: [URL]) {
        let week = currentWeek
        Task {
            let result = await document.importMaterials(
                at: urls, securityScoped: true, week: week)
            if let message = result.errorMessage { materialImportError = message }
            guard let first = result.added.first else { return }
            paneMaterialID = first.id
            if !showingMaterialPane { withAnimation(.snappy) { showingMaterialPane = true } }
        }
    }

    private func toggleMaterialPane() {
        if !showingMaterialPane, paneMaterialID == nil {
            // One file: open it straight away; otherwise the pane asks which one.
            let materials = document.manifest.materialList
            if materials.count == 1 { paneMaterialID = materials[0].id }
        }
        withAnimation(.snappy) { showingMaterialPane.toggle() }
    }
}

// MARK: - UIActivityViewController wrapper for SwiftUI

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
