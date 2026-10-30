import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BrowserModel: ObservableObject {
    @Published var image: RomFSImage?
    @Published var errorText: String?
    @Published var loading = false
    @Published var generation = 0
    private var scopedURL: URL?

    func open(_ url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        loading = true
        errorText = nil
        Task {
            do {
                let opened = try await Task.detached(priority: .userInitiated) { try RomFSImage(url: url) }.value
                image = opened
                generation += 1
            } catch {
                image = nil
                errorText = error.localizedDescription
            }
            loading = false
        }
    }
}

struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if let image = model.image {
                    DirectoryView(image: image, directory: image.root)
                } else {
                    emptyState
                        .navigationTitle("RomFS Browser")
                }
            }
            .navigationDestination(for: RomFSNode.self) { node in
                if let image = model.image {
                    if node.isDirectory {
                        DirectoryView(image: image, directory: node)
                    } else {
                        FileDetailView(image: image, node: node)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { importing = true } label: { Label("Open", systemImage: "folder") }
                }
            }
        }
        .id(model.generation)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { model.open(url) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            if model.loading {
                ProgressView("Reading index")
            } else {
                Text("Open a romfs.img file to see what is inside it.")
                    .multilineTextAlignment(.center)
                Button("Open romfs.img") { importing = true }
                    .buttonStyle(.borderedProminent)
            }
            if let text = model.errorText {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}

struct DirectoryView: View {
    let image: RomFSImage
    let directory: RomFSNode

    @State private var query = ""
    @State private var results: [RomFSNode] = []
    @State private var searching = false

    var body: some View {
        let range = image.childRange(of: directory.id)
        List {
            if query.isEmpty {
                if directory.id == 0 {
                    Section("Image") {
                        row("Entries", "\(image.count)")
                        row("Files", "\(image.fileCount)")
                        row("Data size", formatBytes(image.totalFileBytes))
                        row("Image size", formatBytes(image.fileSize))
                    }
                }
                Section("\(range.count) items") {
                    ForEach(range, id: \.self) { k in
                        if let node = image.node(k) {
                            NavigationLink(value: node) { NodeRow(node: node, subtitle: nil) }
                        }
                    }
                }
            } else {
                Section(searching ? "Searching" : "\(results.count) matches") {
                    ForEach(results) { node in
                        NavigationLink(value: node) {
                            NodeRow(node: node, subtitle: image.path(of: node.id))
                        }
                    }
                }
            }
        }
        .navigationTitle(directory.id == 0 ? image.url.lastPathComponent : directory.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search the whole image")
        .task(id: query) {
            guard !query.isEmpty else { results = []; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            searching = true
            let q = query
            let found = await Task.detached { image.search(q) }.value
            if Task.isCancelled { return }
            results = found
            searching = false
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

struct NodeRow: View {
    let node: RomFSNode
    let subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).lineLimit(2)
                Text(subtitle ?? detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var detail: String {
        node.isDirectory ? "\(node.b) items" : formatBytes(node.b)
    }
}
