import SwiftUI

/// Placeholder sidebar panel shown when the Search tab is active.
struct SidebarSearchView: View {
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .font(.system(size: 12))

            Spacer()
            HStack {
                Spacer()
                Text(query.isEmpty ? "Type to search files" : "Search coming soon")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: AppSettings.shared.theme.chromeMuted).opacity(0.5))
                Spacer()
            }
            Spacer()
        }
    }
}
