//
//  MaterialsView.swift
//  kisaca
//
//  The lecture's materials: scripts, slides, exercise sheets — any file the student
//  wants next to their notes. Reached from its own row at the top of the lecture's
//  home screen, the way a section's Whole Notebook sits above its sessions.
//
//  Files come in through the Files picker or by dragging them onto the list (iPad
//  multitasking), are stored inside the lecture's `.kisaca` package — so they sync and
//  move with it — and open in Quick Look, which handles PDF, Keynote/PowerPoint,
//  Pages/Word, images and plain text, and brings its own share button. Read-only:
//  materials are reference copies, notes go in the notebook (MaterialPreview.swift).
//
//  Storage and why the bytes are not kept in memory: `LectureDocument` → Materials.
//

import SwiftUI
import UniformTypeIdentifiers

struct MaterialsView: View {
    @ObservedObject var document: LectureDocument

    @State private var showingImporter = false
    @State private var searchText = ""
    /// Retained while its preview is on screen — Quick Look holds its data source and
    /// delegate weakly.
    @State private var previewer: MaterialPreviewer?
    @State private var openingID: UUID?
    @State private var renaming: CourseMaterial?
    @State private var renameDraft = ""
    @State private var pendingDeletion: CourseMaterial?
    @State private var importError: String?
    /// Where the files being picked will be filed: a week, or `nil` for the whole lecture.
    @State private var importWeek: Int?

    private var materials: [CourseMaterial] {
        let all = document.manifest.materialList.sorted { $0.addedAt > $1.addedAt }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.originalFileName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        withAlerts(withImport(list))
            .searchable(text: $searchText, prompt: "Search materials")
            .navigationTitle("Materials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Whole Lecture", systemImage: "books.vertical") { addFiles(toWeek: nil) }
                        Menu("Week…", systemImage: "calendar") {
                            ForEach(document.manifest.materialWeekChoices, id: \.self) { week in
                                Button("Week \(week)") { addFiles(toWeek: week) }
                            }
                        }
                    } label: {
                        Label("Add Files", systemImage: "plus")
                    }
                }
            }
    }

    // Split into pieces: as one expression the type checker gives up.

    private var list: some View {
        List {
            ForEach(groups, id: \.week) { group in
                Section {
                    ForEach(group.items) { material in row(for: material) }
                } header: {
                    Text(group.week.map { "Week \($0)" } ?? "Whole Lecture")
                }
            }
        }
        .overlay {
            if document.manifest.materialList.isEmpty {
                ContentUnavailableView {
                    Label("No Materials Yet", systemImage: "doc.on.doc")
                } description: {
                    Text(
                        "Add the lecture's scripts, slides and exercise sheets — from Files, or by dragging them here. File them under the whole lecture or a single week."
                    )
                } actions: {
                    Button("Add Files") { addFiles(toWeek: nil) }
                        .buttonStyle(.borderedProminent)
                }
            } else if materials.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    /// Whole-lecture files first, then one group per week in order.
    private var groups: [(week: Int?, items: [CourseMaterial])] {
        let byWeek = Dictionary(grouping: materials, by: \.week)
        return byWeek.keys.sorted { ($0 ?? 0) < ($1 ?? 0) }.map { ($0, byWeek[$0] ?? []) }
    }

    private func addFiles(toWeek week: Int?) {
        importWeek = week
        showingImporter = true
    }

    @ViewBuilder
    private func row(for material: CourseMaterial) -> some View {
        Button {
            open(material)
        } label: {
            MaterialRow(material: material, isOpening: openingID == material.id)
        }
        .foregroundStyle(.primary)
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameDraft = material.title
                renaming = material
            }
            Menu("Move to", systemImage: "folder") {
                Button("Whole Lecture") {
                    document.setMaterialWeek(nil, forMaterialWithID: material.id)
                }
                ForEach(document.manifest.materialWeekChoices, id: \.self) { week in
                    Button("Week \(week)") {
                        document.setMaterialWeek(week, forMaterialWithID: material.id)
                    }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = material
            }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = material
            }
        }
    }

    private func withImport(_ content: some View) -> some View {
        content
        .fileImporter(
            isPresented: $showingImporter, allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): importFiles(at: urls, securityScoped: true)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .dropDestination(for: DroppedFile.self) { files, _ in
            importWeek = nil
            importFiles(at: files.map(\.url), securityScoped: false)
            return !files.isEmpty
        }
    }

    private func withAlerts(_ content: some View) -> some View {
        content
        .alert(
            "Rename",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { material in
            TextField("Title", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { document.renameMaterial(withID: material.id, to: title) }
            }
        }
        .alert(
            "Delete \"\(pendingDeletion?.title ?? "")\"?",
            isPresented: Binding(
                get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { material in
            Button("Delete", role: .destructive) { document.removeMaterial(withID: material.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The file is removed from this lecture. This can't be undone.")
        }
        .alert(
            "Couldn't Add File",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Import

    private func importFiles(at urls: [URL], securityScoped: Bool) {
        let week = importWeek
        Task {
            let result = await document.importMaterials(
                at: urls, securityScoped: securityScoped, week: week)
            if let message = result.errorMessage { importError = message }
        }
    }

    // MARK: - Open

    /// Writes the file under its original name to a temporary folder and hands it to
    /// Quick Look — which needs a file URL, and shows that name in its title and when
    /// sharing. Read-only — see `MaterialPreviewer`.
    private func open(_ material: CourseMaterial) {
        guard openingID == nil else { return }
        openingID = material.id
        Task {
            defer { openingID = nil }
            guard let data = await document.materialData(for: material) else {
                importError = "\"\(material.title)\" couldn't be read from the lecture file."
                return
            }
            do {
                let url = try MaterialFiles.temporaryCopy(of: material, data: data)
                let previewer = MaterialPreviewer(
                    fileURL: url, onDismiss: { self.previewer = nil })
                self.previewer = previewer
                previewer.present()
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

private struct MaterialRow: View {
    let material: CourseMaterial
    let isOpening: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: material.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(material.title)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isOpening { ProgressView() }
        }
        .contentShape(Rectangle())
    }

    private var details: String {
        let ext = (material.originalFileName as NSString).pathExtension.uppercased()
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(material.byteCount), countStyle: .file)
        let added = material.addedAt.formatted(date: .abbreviated, time: .omitted)
        return [ext.isEmpty ? nil : ext, size, added].compactMap { $0 }.joined(separator: " · ")
    }

}

extension CourseMaterial {
    var contentType: UTType? { contentTypeIdentifier.flatMap(UTType.init) }

    /// SF Symbol for the file's kind — shared by the Materials list and the notebook's
    /// material pane.
    var symbolName: String {
        guard let type = contentType else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .audiovisualContent) { return "play.rectangle" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if type.conforms(to: .text) { return "doc.plaintext" }
        return "doc"
    }
}

// MARK: - Drag and drop

/// A file dropped onto the list, copied out of the drop's temporary location (which
/// is deleted as soon as the drop completes) into one of our own.
nonisolated struct DroppedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("DroppedMaterials", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return DroppedFile(url: destination)
        }
    }
}

#Preview {
    let doc = LectureDocument()
    doc.manifest.materials = [
        CourseMaterial(
            title: "Analysis II Script", originalFileName: "Analysis II Script.pdf",
            contentTypeIdentifier: UTType.pdf.identifier, byteCount: 12_400_000),
        CourseMaterial(
            title: "Week 3 Slides", originalFileName: "Week 3 Slides.key",
            contentTypeIdentifier: "com.apple.keynote.key", byteCount: 3_200_000),
    ]
    return NavigationStack { MaterialsView(document: doc) }
}

// MARK: - Import (shared with the notebook's Add Material)

extension LectureDocument {
    /// Reads each file off the main actor, then adds it to the lecture's materials under
    /// `week` (`nil` = the whole lecture). Files from the picker are security-scoped;
    /// dropped files were already copied somewhere we own.
    func importMaterials(at urls: [URL], securityScoped: Bool, week: Int?) async
        -> (added: [CourseMaterial], errorMessage: String?)
    {
        var added: [CourseMaterial] = []
        var failed: [String] = []
        for url in urls {
            let loaded = await Task.detached { () -> (Data, UTType?)? in
                let accessing = securityScoped && url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                let type =
                    (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    ?? UTType(filenameExtension: url.pathExtension)
                return (data, type)
            }.value
            guard let (data, type) = loaded else {
                failed.append(url.lastPathComponent)
                continue
            }
            added.append(
                addMaterial(
                    data: data, fileName: url.lastPathComponent, contentType: type, week: week))
        }
        let message = failed.isEmpty ? nil : "Couldn't read " + failed.joined(separator: ", ") + "."
        return (added, message)
    }
}
