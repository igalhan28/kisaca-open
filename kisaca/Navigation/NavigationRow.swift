//
//  NavigationRow.swift
//  kisaca
//
//  A list row that opens another screen, for SwiftUI screens that UIKit pushes
//  (`AppCoordinator`). They have no `NavigationStack`, so `NavigationLink` can't push
//  from them; this looks like one — the label, then a disclosure chevron — and calls
//  `action`, which pushes through the coordinator. Goes away with the SwiftUI screens
//  (docs/uikit-migration.md).
//

import SwiftUI

struct NavigationRow<Label: View>: View {
    let action: () -> Void
    let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            HStack {
                label
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
