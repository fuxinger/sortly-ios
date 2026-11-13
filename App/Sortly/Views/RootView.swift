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
                Label("SORTLY konnte nicht starten", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
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

    var body: some View {
        TabView {
            Tab("Übersicht", systemImage: "square.grid.2x2") {
                NavigationStack { OverviewView() }
            }
            Tab("Mediathek", systemImage: "photo.on.rectangle") {
                NavigationStack { LibraryView() }
            }
            Tab("Alben", systemImage: "folder") {
                NavigationStack { AlbumsView() }
            }
            Tab(role: .search) {
                NavigationStack { SearchView() }
            }
        }
        .alert("Hinweis", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}
