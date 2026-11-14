import SwiftUI
import SortlyCore

/// Albums SORTLY created or extended. Each one can be taken back: SORTLY removes only the
/// photos it added itself and deletes an album only if it created it and nothing else is in it.
struct ManagedAlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: ManagedAlbumState?
    @State private var plan: ChangePlan?
    @State private var showPlan = false
    @State private var removingSource: SortlyID?
    @State private var nothingToDo = false

    var body: some View {
        List {
            if model.managedAlbums.isEmpty {
                ContentUnavailableView("Noch keine Alben", systemImage: "rectangle.stack",
                                       description: Text("Hier erscheinen Alben, die SORTLY angelegt oder ergänzt hat."))
            } else {
                Section {
                    ForEach(model.managedAlbums, id: \.albumID) { state in
                        Button { pending = state } label: { row(state) }
                            .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("Tippe auf ein Album, um SORTLYs Änderungen daran zurückzunehmen. Fotos, die du selbst hinzugefügt hast, bleiben drin. Deine Originale bleiben immer in der Mediathek.")
                }
            }
        }
        .navigationTitle("Von SORTLY angelegt")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pending.map { Text("„\($0.lastKnownTitle)“ zurücknehmen?") } ?? Text(""),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { state in
            Button(state.createdBySortly ? "Album entfernen" : "SORTLYs Fotos herausnehmen", role: .destructive) {
                Task { await prepare(state) }
            }
        } message: { state in
            if state.createdBySortly {
                Text("SORTLY hat dieses Album angelegt. Es wird gelöscht, die Fotos bleiben in deiner Mediathek. Hast du selbst Fotos hineingelegt, bleibt das Album mit diesen Fotos bestehen.")
            } else {
                Text("Die \(state.addedBySortly.count) Fotos, die SORTLY hinzugefügt hat, werden aus dem Album genommen. Alles andere bleibt, wie es ist.")
            }
        }
        .alert("Nichts zu tun", isPresented: $nothingToDo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Fotos von SORTLY sind schon nicht mehr in diesem Album.")
        }
        .navigationDestination(isPresented: $showPlan) {
            PlanReviewView(prebuilt: plan)
        }
        .onChange(of: model.execution.finished) { _, finished in
            guard finished != nil, let source = removingSource else { return }
            removingSource = nil
            Task { await model.forgetProposal(source) }
        }
    }

    private func row(_ state: ManagedAlbumState) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(systemName: state.createdBySortly ? "rectangle.stack.badge.plus" : "plus.rectangle.on.rectangle", tint: Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.lastKnownTitle).font(.body.weight(.medium))
                Group {
                    if state.createdBySortly {
                        Text("Neu angelegt · \(state.addedBySortly.count) Fotos von SORTLY")
                    } else {
                        Text("Ergänzt · \(state.addedBySortly.count) Fotos von SORTLY")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Änderungen von SORTLY zurücknehmen"))
    }

    private func prepare(_ state: ManagedAlbumState) async {
        pending = nil
        guard let removal = await model.removalPlan(for: state) else {
            nothingToDo = true
            return
        }
        removingSource = state.sourceID
        plan = removal
        showPlan = true
    }
}
