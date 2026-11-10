//
//  LibrarySettingsView.swift
//  kisaca
//
//  The home screen's Settings: where lectures are stored, and the device preferences
//  from AppPreferences.
//

import SwiftUI

struct LibrarySettingsView: View {
    @Environment(LectureLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// Reports how tall the form's content is, so the presenting sheet can hug it
    /// instead of leaving empty space under the last section.
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    @AppStorage(AppPreferences.Key.materialPaneSide)
    private var paneSideRaw = MaterialPaneSide.default.rawValue

    @AppStorage(AppPreferences.Key.notebookFitsWidth)
    private var notebookFitsWidth = false

    @AppStorage(AppPreferences.Key.leftHanded)
    private var leftHanded = false

    private var materialOpensOnLeft: Bool {
        (MaterialPaneSide(rawValue: paneSideRaw) ?? .default).isOnLeft(leftHanded: leftHanded)
    }

    @State private var isMoving = false
    @State private var moveResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Lectures are saved in") {
                        Text(library.usesICloud ? "iCloud Drive › KISACA" : "On My iPad › KISACA")
                    }
                    if library.usesICloud, library.localLectureCount > 0 {
                        Button {
                            moveToICloud()
                        } label: {
                            HStack {
                                Text("Move \(library.localLectureCount) Lecture\(library.localLectureCount == 1 ? "" : "s") on This Device to iCloud")
                                if isMoving {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isMoving)
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text(
                        library.usesICloud
                            ? "Your lectures sync to your other devices through iCloud. Use Import to bring in .kisaca files kept anywhere else."
                            : "iCloud Drive isn't available for KISACA, so lectures are kept on this device only. Sign in to iCloud and turn on iCloud Drive to sync them."
                    )
                }

                Section {
                    Picker("Opens", selection: $paneSideRaw) {
                        Text("Next to Sidebar").tag(MaterialPaneSide.besideSidebar.rawValue)
                        Text("Opposite Side").tag(MaterialPaneSide.oppositeSidebar.rawValue)
                    }
                    Toggle("Fit Notebook Page to Width", isOn: $notebookFitsWidth)
                } header: {
                    Text("Material Beside Notes")
                } footer: {
                    Text("Material opens on the \(materialOpensOnLeft ? "left" : "right") of your notes.")
                }

                Section {
                    Toggle("Left-Handed", isOn: $leftHanded)
                } header: {
                    Text("Sidebar")
                } footer: {
                    Text("The notebook's sidebar runs down the \(leftHanded ? "right" : "left") edge of the screen, away from your writing hand.")
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                onContentHeightChange(height)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Moved to iCloud",
                isPresented: Binding(get: { moveResult != nil }, set: { if !$0 { moveResult = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(moveResult ?? "")
            }
        }
    }

    private func moveToICloud() {
        isMoving = true
        Task {
            let failed = await library.moveLocalLecturesToICloud()
            isMoving = false
            moveResult =
                failed.isEmpty
                ? "All lectures on this device are now in iCloud."
                : "These couldn't be moved: " + failed.joined(separator: ", ") + "."
        }
    }
}
