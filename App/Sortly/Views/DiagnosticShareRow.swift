import SwiftUI

/// "Diagnose teilen" (I16): a text for support with app, device and plan states, counts and
/// reason codes. No photos, album names or places; the user sees it in the share sheet first.
struct DiagnosticShareRow: View {
    @Environment(AppModel.self) private var model
    @State private var report: String?

    var body: some View {
        Group {
            if let report {
                ShareLink(item: report, subject: Text("Albumist-Diagnose")) {
                    Label("Diagnose teilen", systemImage: "stethoscope")
                }
            } else {
                Label("Diagnose teilen", systemImage: "stethoscope").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("diagnostics.share")
        .task { report = await model.diagnosticReport(device: DeviceInfo.model, system: DeviceInfo.system) }
    }
}
