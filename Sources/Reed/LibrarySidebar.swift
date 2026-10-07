import SwiftUI
#if SWIFT_PACKAGE
import ReedCore
#endif

/// The library's sidebar: its collections, the book shelves, and where to discover articles, each with how many it holds.
/// A view of its own, so typing a search in the article list doesn't count them again.
struct LibrarySidebar: View {
    let library: Library
    @Binding var selection: SidebarItem?
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                Image("ReedMark").renderingMode(.template).resizable().frame(width: 34, height: 34)
                    .foregroundStyle(ReedStyle.accent)
                Text("reed").font(.system(size: 34, weight: .regular, design: .serif)).tracking(-1.8)
                Spacer()
                #if os(iOS)
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .labelStyle(.iconOnly).font(.title3).foregroundStyle(.secondary)
                #endif
            }
            .padding(.horizontal, 22).padding(.top, 24).padding(.bottom, 30)
            List(selection: $selection) {
                Section {
                    ForEach(CollectionFilter.allCases) { item in
                        NavigationLink(value: SidebarItem.collection(item)) {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol).frame(width: 18)
                                Text(item.rawValue)
                                Spacer(minLength: 2)
                                Text("\(library.articles.filter { item.includes($0) }.count)")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                } header: { Text("LIBRARY").font(.system(size: 10, weight: .medium)).tracking(1.7) }
                Section {
                    ForEach(BookFilter.allCases) { item in
                        NavigationLink(value: SidebarItem.books(item)) {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol).frame(width: 18)
                                Text(item.rawValue)
                                Spacer(minLength: 2)
                                Text("\(library.books.filter { item.includes($0) }.count)")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        }
                    }
                } header: { Text("BOOKS").font(.system(size: 10, weight: .medium)).tracking(1.7) }
                Section {
                    ForEach(ExternalSource.allCases.filter { $0 != .substack || SubstackAccount.shared.isSignedIn }) { source in
                        discoverLink(.frontPage(source), symbol: source.symbol)
                    }
                    discoverLink(.feeds, symbol: "dot.radiowaves.up.forward")
                } header: { Text("DISCOVER").font(.system(size: 10, weight: .medium)).tracking(1.7) }
                Section {
                    NavigationLink(value: SidebarItem.stats) {
                        HStack(spacing: 10) {
                            Image(systemName: "chart.bar").frame(width: 18)
                            Text("Statistics")
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Reed")
        #if os(macOS)
        .toolbar(removing: .title)
        #else
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private func discoverLink(_ origin: Discover, symbol: String) -> some View {
        NavigationLink(value: SidebarItem.discover(origin)) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                Text(origin.title)
            }
            .padding(.vertical, 5)
        }
    }
}
