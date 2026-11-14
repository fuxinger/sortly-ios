import SwiftUI
import SortlyCore

/// "Reise anpassen" (I07): a trip Albumist cut wrongly is split at a day or merged with the
/// trip right before or after it. The change is kept in time, so every later analysis holds
/// to it; the settings can take all of them back.
struct TripWorkshopView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var proposal: AlbumProposal
    /// Called after a change: the suggestion this sheet came from no longer exists.
    var onChanged: () -> Void

    private enum Outcome { case split, merged }
    private enum Side { case before, after }

    @State private var splitIndex: Int?
    @State private var working: Outcome?
    @State private var done: Outcome?
    @State private var merging: Side?
    @State private var failed = false

    var body: some View {
        let days = TripWorkshop.days(of: proposal.assetIDs, dates: model.creationDates, calendar: .current)
        List {
            if let done {
                finished(done)
            } else if let working {
                Section {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView()
                        Text(working == .split ? "Albumist teilt die Reise und plant die Vorschläge neu …" : "Albumist legt die Reisen zusammen und plant die Vorschläge neu …")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            } else {
                header(days)
                splitSection(days)
                if let index = splitIndex, let preview = TripWorkshop.split(days, before: index, dates: model.creationDates) {
                    previewSection(preview)
                }
                mergeSection
            }
        }
        .navigationTitle("Reise anpassen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if done == nil && working == nil {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(working != nil)
        // The change shows once the analysis that applies it has finished.
        .onChange(of: model.analysis.isRunning) { _, running in
            guard !running, let finished = working else { return }
            withAnimation(.smooth) {
                working = nil
                done = finished
            }
        }
        .alert("Gerade nicht möglich", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Albumist analysiert oder ändert gerade deine Mediathek. Versuche es gleich noch einmal.")
        }
    }

    // MARK: Sections

    private func header(_ days: [TripWorkshop.Day]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                let dayCount = Text("\(days.count) Tage")
                let photoCount = Text("\(proposal.assetIDs.count) Fotos mit Ort")
                Text(title(proposal)).font(.headline)
                Text("\(dayCount) · \(photoCount)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Hat Albumist hier zwei Reisen zusammengefasst oder eine Reise zerschnitten? Das korrigierst du hier. Albumist merkt es sich auch für jede spätere Analyse.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func splitSection(_ days: [TripWorkshop.Day]) -> some View {
        if days.count > 1 {
            Section {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    if index == 0 {
                        DayRow(day: day, note: String(localized: "Beginn der Reise"), selected: false)
                    } else {
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { splitIndex = splitIndex == index ? nil : index }
                        } label: {
                            DayRow(day: day, note: splitIndex == index ? String(localized: "Neue Reise ab hier") : nil,
                                   selected: splitIndex == index)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("workshop.day")
                        .accessibilityHint(Text("Neue Reise ab diesem Tag"))
                        .accessibilityAddTraits(splitIndex == index ? .isSelected : [])
                    }
                }
            } header: {
                Text("An einem Tag teilen")
            } footer: {
                Text("Tippe auf den Tag, an dem die zweite Reise beginnt.")
            }
        }
    }

    private func previewSection(_ preview: TripWorkshop.Split) -> some View {
        let minimum = model.settings.trips.minPhotos
        return Section {
            PartRow(number: 1, part: preview.first)
            PartRow(number: 2, part: preview.second)
            if preview.first.count < minimum || preview.second.count < minimum {
                Label("Ein Teil hat weniger als \(minimum) Fotos mit Ort. Er wird kein eigener Reise-Vorschlag; seine Fotos bleiben in den Länder- und Orte-Alben.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                guard let index = splitIndex else { return }
                let day = TripWorkshop.days(of: proposal.assetIDs, dates: model.creationDates, calendar: .current)[index]
                Task {
                    if await model.splitTrip(at: day) { working = .split } else { failed = true }
                }
            } label: {
                Label("Reise teilen", systemImage: "scissors")
            }
            .buttonStyle(PrimaryButtonStyle())
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .disabled(model.analysis.isRunning || model.execution.isRunning)
            .accessibilityIdentifier("workshop.split")
        } header: {
            Text("Daraus werden zwei Reisen")
        }
    }

    @ViewBuilder
    private var mergeSection: some View {
        let around = model.tripNeighbours(of: proposal)
        if around.before != nil || around.after != nil {
            Section {
                if let before = around.before {
                    mergeButton(before, side: .before)
                }
                if let after = around.after {
                    mergeButton(after, side: .after)
                }
            } header: {
                Text("Zusammenlegen")
            } footer: {
                Text("Für eine Reise mit Pause, zum Beispiel ein Wochenende zu Hause zwischen zwei Stationen.")
            }
        }
    }

    private func mergeButton(_ other: AlbumProposal, side: Side) -> some View {
        Button {
            merging = side
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                let photos = Text("\(other.assetIDs.count) Fotos")
                VStack(alignment: .leading, spacing: 2) {
                    Text(side == .before ? "Mit der Reise davor zusammenlegen" : "Mit der Reise danach zusammenlegen")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text("\(title(other)) · \(photos)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.analysis.isRunning || model.execution.isRunning)
        .accessibilityIdentifier(side == .before ? "workshop.merge.before" : "workshop.merge.after")
        .confirmationDialog("Zu einer Reise zusammenlegen?", isPresented: Binding(get: { merging == side }, set: { if !$0 { merging = nil } }),
                            titleVisibility: .visible) {
            Button("Zusammenlegen") {
                Task {
                    let (first, second) = side == .before ? (other, proposal) : (proposal, other)
                    if await model.mergeTrips(first, second) { working = .merged } else { failed = true }
                }
            }
        } message: {
            Text("„\(title(other))“ und „\(title(proposal))“ werden eine Reise mit \(other.assetIDs.count + proposal.assetIDs.count) Fotos.")
        }
    }

    private func finished(_ outcome: Outcome) -> some View {
        Section {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: done != nil)
                    .accessibilityHidden(true)
                Text(outcome == .split ? "Aus einer Reise sind zwei geworden." : "Die zwei Reisen sind jetzt eine.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Die Vorschläge sind schon angepasst. Albumist hält sich daran, auch bei jeder neuen Analyse. Zurücknehmen kannst du es in den Einstellungen.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
            Button("Zu den Reisen") {
                dismiss()
                onChanged()
            }
            .buttonStyle(PrimaryButtonStyle())
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier("workshop.done")
        }
    }

    private func title(_ proposal: AlbumProposal) -> String {
        model.userTitles[proposal.id] ?? proposal.title
    }
}

/// One day of the trip: first photo, date, number of photos, and the split mark.
private struct DayRow: View {
    var day: TripWorkshop.Day
    var note: String?
    var selected: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            AssetThumbnail(id: day.assetIDs[0], side: 88)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(day.start.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                Text("\(day.count) Fotos").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.s)
            if let note {
                if selected {
                    Label(note, systemImage: "scissors")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One of the two trips a split makes.
private struct PartRow: View {
    var number: Int
    var part: TripWorkshop.Part

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(number.formatted())
                .font(.headline)
                .foregroundStyle(Theme.onAccent)
                .frame(width: 28, height: 28)
                .background(Theme.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(span)
                Text("\(part.count) Fotos").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var span: String {
        if Calendar.current.isDate(part.start, inSameDayAs: part.end) {
            return part.start.formatted(.dateTime.day().month(.wide).year())
        }
        return (part.start..<part.end).formatted(.interval.day().month(.wide).year())
    }
}
