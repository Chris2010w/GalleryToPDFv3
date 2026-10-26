import SwiftUI

struct ComicItem: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
}

final class LibraryModel: ObservableObject {
    @Published var items: [ComicItem] = []
    @Published var loading = false
    @Published var folderMissing = false
    private var scopedURL: URL?

    func reload(bookmark: Data?) {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil

        guard let bookmark, let url = FolderAccess.resolve(bookmark) else {
            items = []
            folderMissing = true
            return
        }
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        folderMissing = false
        loading = true

        DispatchQueue.global(qos: .userInitiated).async {
            var found: [ComicItem] = []
            let fm = FileManager.default
            if let en = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for case let file as URL in en {
                    let ext = file.pathExtension.lowercased()
                    if ext == "cbz" || ext == "pdf" {
                        found.append(ComicItem(url: file))
                    }
                }
            }
            found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.items = found
                self.loading = false
            }
        }
    }
}

final class CoverCache {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, UIImage>()

    func cover(for item: ComicItem) async -> UIImage? {
        let key = item.id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = item.url
        let image = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let doc = ComicLoader.open(url: url) else { return nil }
            return doc.image(at: 0, maxDimension: 400)
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

struct CoverView: View {
    let item: ComicItem
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: item.isPDF ? "doc.richtext" : "books.vertical")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }
            }
            .clipped()
            .task { image = await CoverCache.shared.cover(for: item) }
    }
}

struct LibraryView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var model = LibraryModel()

    @State private var selected: ComicItem?
    @State private var showSettings = false
    @State private var search = ""
    @State private var showDA = false

    private var filtered: [ComicItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return model.items }
        return model.items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.folderMissing {
                    emptyState(icon: "folder.badge.questionmark",
                               text: "Δεν βρέθηκε ο φάκελος. Διάλεξε ξανά φάκελο από τις Ρυθμίσεις.")
                } else if model.items.isEmpty && !model.loading {
                    emptyState(icon: "tray",
                               text: "Δεν βρέθηκαν αρχεία CBZ ή PDF σε αυτόν τον φάκελο.")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 14)], spacing: 18) {
                            ForEach(filtered) { item in
                                Button { selected = item } label: { cell(item) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            }
            .fullScreenCover(isPresented: $showDA) { DADownloaderView() }
            .navigationTitle("Βιβλιοθήκη")
            .searchable(text: $search)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showDA = true } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    Button { model.reload(bookmark: settings.folderBookmark) } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
        }
        .task { model.reload(bookmark: settings.folderBookmark) }
        .onChange(of: settings.folderBookmark) { newValue in
            model.reload(bookmark: newValue)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings)
        }
        .fullScreenCover(item: $selected) { item in
            ReaderView(item: item).environmentObject(settings)
        }
    }

    private func cell(_ item: ComicItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(item: item)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    Text(item.isPDF ? "PDF" : "CBZ")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                        .padding(5)
                }
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 48))
            Text(text).multilineTextAlignment(.center)
            Button("Ρυθμίσεις") { showSettings = true }
        }
        .foregroundColor(.secondary)
        .padding(32)
    }
}
