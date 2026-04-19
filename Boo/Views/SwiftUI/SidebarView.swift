import SwiftUI

/// SwiftUI sidebar showing plugin tabs as a List.
/// Replaces SidebarTabBarView + DetailPanelView (AppKit).
struct SidebarView: View {
    let tabs: [SidebarTab]
    @Binding var selectedTabID: SidebarTabID?

    var body: some View {
        List(tabs, id: \.id, selection: $selectedTabID) { tab in
            Label {
                Text(tab.label)
                    .font(.system(size: 13))
            } icon: {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
            }
            .tag(tab.id)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }
}

/// Detail area for the currently selected plugin tab — renders its sections.
struct PluginTabDetailView: View {
    let tab: SidebarTab
    @Binding var expandedSections: Set<String>

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(tab.sections) { section in
                    if tab.sections.count == 1 {
                        // Single section — no header, full height
                        section.content
                    } else {
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedSections.contains(section.id) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedSections.insert(section.id)
                                    } else {
                                        expandedSections.remove(section.id)
                                    }
                                }
                            )
                        ) {
                            section.content
                        } label: {
                            Label(section.name, systemImage: section.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                        }
                        .padding(.horizontal, 8)

                        Divider()
                    }
                }
            }
        }
    }
}
