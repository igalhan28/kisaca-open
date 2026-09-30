//
//  AddSessionSheet.swift
//  kisaca
//
//  "New Session": a date and time for a session added by hand — a make-up lecture, an
//  extra exercise sheet. Presented by `SectionSessionsViewController`. One of the forms
//  that stays SwiftUI for now (docs/uikit-migration.md → Phase 5).
//

import SwiftUI

struct AddSessionSheet: View {
    @State var date: Date
    var onCancel: () -> Void
    var onAdd: (Date) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Date", selection: $date)
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(date) }
                }
            }
        }
    }
}
