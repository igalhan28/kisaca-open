//
//  MaterialPane.swift
//  kisaca
//
//  A course material open beside the notebook — the script on one side, notes on the
//  other. Shown by `NotebookScreen`'s split button; which side it sits on and how wide
//  it is are device preferences (`AppPreferences`).
//
//  PDFs (the common case: scripts, exercise sheets) open in PDFKit — continuous scroll,
//  pinch zoom, text selection. Anything else (slides, images, documents) opens in an
//  embedded Quick Look view. Markup is deliberately not offered here: it is Quick Look's
//  full-screen feature, reached from the Materials list (`MaterialPreviewer`), and the
//  pencil on this screen belongs to the notebook.
//

import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct MaterialPane: View {
    let document: LectureDocument
    /// The material shown; `nil` shows a picker.
    @Binding var materialID: UUID?
    var onClose: () -> Void
    /// Week of the session being written — its materials are listed first.
    var currentWeek: Int?
    /// Opens the file picker to add material without leaving the notebook.
    var onAdd: () -> Void = {}
    /// Called once a material is on screen. Showing a PDF can take first responder
    /// (and with it the notebook's tool picker); the notebook uses this to take it back.
    var onContentShown: () -> Void = {}

    @State private var content: LoadedContent?

    private enum LoadedContent {
        case pdf(PDFDocument)
        case file(URL)
        case failed(String)
    }

    private var materials: [CourseMaterial] {
        // This week's files, then the whole lecture's, then other weeks; newest first within.
        func rank(_ m: CourseMaterial) -> Int {
            if let week = m.week { return week == currentWeek ? 0 : 2 }
            return 1
        }
        return document.manifest.materialList.sorted {
            (rank($0), $1.addedAt) < (rank($1), $0.addedAt)
        }
    }

    private func label(for item: CourseMaterial) -> String {
        item.week.map { "\(item.title) · W\($0)" } ?? item.title
    }

    private var material: CourseMaterial? {
        materialID.flatMap { id in materials.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content(for: material)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.secondarySystemBackground))
        .task(id: materialID) { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(materials) { item in
                    Button {
                        materialID = item.id
                    } label: {
                        Label(label(for: item), systemImage: item.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: material?.symbolName ?? "tray.full")
                    Text(material?.title ?? "Materials")
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.medium))
            }
            .disabled(materials.isEmpty)

            Spacer(minLength: 0)

            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Add Material")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Close Material")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for material: CourseMaterial?) -> some View {
        if materials.isEmpty {
            ContentUnavailableView {
                Label("No Materials", systemImage: "tray")
            } description: {
                Text("Add scripts and slides to read them here while you write.")
            } actions: {
                Button("Add Material", action: onAdd)
                    .buttonStyle(.borderedProminent)
            }
        } else if material == nil {
            picker
        } else {
            switch content {
            case .none:
                ProgressView()
            case .pdf(let pdf):
                PDFKitView(document: pdf)
            case .file(let url):
                QuickLookView(url: url)
            case .failed(let message):
                ContentUnavailableView(
                    "Can't Open", systemImage: "exclamationmark.triangle",
                    description: Text(message))
            }
        }
    }

    private var picker: some View {
        List(materials) { item in
            Button {
                materialID = item.id
            } label: {
                Label(label(for: item), systemImage: item.symbolName)
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Loading

    private func load() async {
        content = nil
        guard let material else { return }
        guard let data = await document.materialData(for: material) else {
            content = .failed("\"\(material.title)\" couldn't be read from the lecture file.")
            return
        }
        guard !Task.isCancelled else { return }
        if material.contentType?.conforms(to: .pdf) == true, let pdf = PDFDocument(data: data) {
            content = .pdf(pdf)
        } else {
            do {
                content = .file(try MaterialFiles.temporaryCopy(of: material, data: data))
            } catch {
                content = .failed(error.localizedDescription)
                return
            }
        }
        // After the view has been installed, which is when it would take first responder.
        try? await Task.sleep(for: .milliseconds(300))
        if !Task.isCancelled { onContentShown() }
    }
}

// MARK: - PDFKit

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        view.backgroundColor = .secondarySystemBackground
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
    }
}

// MARK: - Quick Look (embedded)

private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int)
            -> any QLPreviewItem
        {
            url as NSURL
        }
    }
}
