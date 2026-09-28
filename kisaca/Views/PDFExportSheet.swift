//
//  PDFExportSheet.swift
//  kisaca
//
//  Implements the project brief's "exporting selected / all pages to PDF" requirement.
//  Presented from NotebookScreen's Export button. "All Pages" exports the whole
//  notebook (one session, or a whole section); "Select Pages" shows a thumbnail grid (reusing cached page thumbnails,
//  same ones the canvas uses for neighbour snapshots) with checkboxes.
//

import SwiftUI
import UIKit

struct PDFExportSheet: View {
    let document: LectureDocument
    /// "W3 · Mon", or "Lectures · …" for a whole section — used in the file name.
    let notebookTitle: String
    var coordinator: NotebookCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ExportMode = .all
    @State private var selectedIndices: Set<Int> = []

    private enum ExportMode: String, CaseIterable {
        case all = "All Pages"
        case select = "Select Pages"
    }

    /// The open notebook's pages — one session's, or a whole section's.
    private var pageIDs: [UUID] { coordinator.pageRepository?.pageIDs ?? [] }

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Export mode", selection: $mode) {
                    ForEach(ExportMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch mode {
                case .all:
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.on.doc")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("\(pageIDs.count) page\(pageIDs.count == 1 ? "" : "s") will be exported.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                case .select:
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(Array(pageIDs.enumerated()), id: \.offset) { index, pageID in
                                PageThumbnailCell(
                                    document: document,
                                    pageID: pageID,
                                    pageNumber: index + 1,
                                    isSelected: selectedIndices.contains(index)
                                )
                                .onTapGesture { toggleSelection(index) }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Export PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { export() }
                        .disabled(mode == .select && selectedIndices.isEmpty)
                }
            }
            .onAppear {
                // Default "Select Pages" to everything checked so users only need to
                // uncheck the pages they want to exclude.
                if selectedIndices.isEmpty {
                    selectedIndices = Set(pageIDs.indices)
                }
            }
        }
    }

    private func toggleSelection(_ index: Int) {
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
    }

    private func export() {
        let indices: [Int]? = mode == .all ? nil : selectedIndices.sorted()
        coordinator.generatePDF(pageIndices: indices, fileName: exportFileName())
        dismiss()
    }

    /// e.g. "Calculus II - Exercise Sessions - W3 · Tue", or "Calculus II - Lectures"
    /// for a whole section.
    private func exportFileName() -> String {
        guard let repository = coordinator.pageRepository else { return "KISACA Notebook" }
        let parts: [String?]
        switch repository.scope {
        case .session(let id):
            let session = document.manifest.sessions.first { $0.id == id }
            parts = [
                document.manifest.name,
                session.flatMap { document.manifest.section(withID: $0.sectionID)?.name },
                session.map { document.manifest.title(for: $0) },
            ]
        case .section(let id):
            parts = [document.manifest.name, document.manifest.section(withID: id)?.name]
        }
        let named = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return named.isEmpty ? notebookTitle : named.joined(separator: " - ")
    }
}

// MARK: - Page thumbnail cell

private struct PageThumbnailCell: View {
    let document: LectureDocument
    let pageID: UUID
    let pageNumber: Int
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailImage
                    .aspectRatio(595.0 / 842.0, contentMode: .fit)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                                lineWidth: isSelected ? 3 : 1)
                    )

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, isSelected ? Color.accentColor : Color.gray)
                    .background(Circle().fill(Color.white))
                    .padding(4)
            }
            Text("\(pageNumber)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        let _ = document.pageContentRevision  // thumbnails aren't observed themselves
        if let data = document.getThumbnailData(for: pageID), let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
        } else {
            Color.white
                .overlay(
                    Image(systemName: "doc.text")
                        .foregroundStyle(Color.gray.opacity(0.4))
                )
        }
    }
}

#Preview {
    let doc = LectureDocument()
    let section = LectureSection.recommendedDefaults()[0]
    let session = LectureSession(sectionID: section.id, date: Date())
    doc.manifest.sections = [section]
    doc.manifest.sessions = [session]
    let coordinator = NotebookCoordinator()
    coordinator.pageRepository = PageRepository(document: doc, scope: .session(session.id))
    return PDFExportSheet(document: doc, notebookTitle: "Preview", coordinator: coordinator)
}
