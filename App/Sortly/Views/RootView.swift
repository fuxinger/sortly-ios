import SwiftUI
import SortlyCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            ContentUnavailableView {
                Label("Albumist konnte nicht starten", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                // A damaged database is no dead end: Albumist's own data can always be rebuilt
                // from the library. Photos, albums and the purchase are not affected.
                Button("Neu aufbauen") { Task { await model.rebuildAfterFailure() } }
                    .buttonStyle(.borderedProminent)
                if AppModel.safetyBackupDate() != nil {
                    Text("Albumist beginnt dann neu und holt deine Entscheidungen aus der Sicherung zurück. Deine Fotos, Alben und dein Kauf bleiben, wie sie sind.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Albumist beginnt dann neu. Deine Fotos, Alben und dein Kauf bleiben, wie sie sind.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .onboarding:
            OnboardingView()
        case .ready:
            MainTabs()
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @State private var tab: MainTab = .overview

    enum MainTab: Hashable { case overview, library, albums, search }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Übersicht", systemImage: "square.grid.2x2", value: MainTab.overview) {
                NavigationStack {
                    OverviewView()
                        .navigationDestination(item: route) { RouteDestination(route: $0) }
                }
            }
            Tab("Mediathek", systemImage: "photo.on.rectangle", value: MainTab.library) {
                NavigationStack { LibraryView() }
            }
            Tab("Alben", systemImage: "folder", value: MainTab.albums) {
                NavigationStack { AlbumsView() }
            }
            Tab(value: MainTab.search, role: .search) {
                NavigationStack { SearchView() }
            }
        }
        // iPad: tabs become a sidebar; iPhone: the Liquid Glass tab bar shrinks while scrolling.
        .tabViewStyle(.sidebarAdaptable)
        // UI tests tap every tab by name; a shrunken bar hides all but the current one.
        .tabBarMinimizeBehavior(UITestSupport.isRunning ? .never : .onScrollDown)
        // Siri, Shortcuts and Spotlight open their target from the overview.
        .onChange(of: model.route, initial: true) { _, target in
            if target != nil { tab = .overview }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }

    private var route: Binding<AppModel.Route?> {
        Binding(get: { model.route }, set: { model.route = $0 })
    }
}

/// A screen opened from Siri, Shortcuts or Spotlight.
struct RouteDestination: View {
    @Environment(AppModel.self) private var model
    var route: AppModel.Route

    var body: some View {
        switch route {
        case .country(let code):
            CountryPhotosView(code: code, year: nil)
        case .suggestion(let id):
            if let proposal = model.proposals.first(where: { $0.id == id }) {
                ProposalDetailView(proposal: proposal)
            } else {
                ContentUnavailableView("Vorschlag nicht gefunden", systemImage: "rectangle.stack",
                                       description: Text("Dieser Vorschlag ist schon erledigt oder nicht mehr aktuell."))
            }
        }
    }
}
