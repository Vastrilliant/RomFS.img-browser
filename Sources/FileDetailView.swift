import SwiftUI
import UIKit

struct FileDetailView: View {
    let image: RomFSImage
    let node: RomFSNode

    @State private var preview = Data()

    var body: some View {
        List {
            Section("File") {
                info("Name", node.name)
                info("Path", image.path(of: node.id))
                info("Size", "\(formatBytes(node.b)) (\(node.b) bytes)")
                info("Offset in image", "0x" + String(node.a, radix: 16))
                info("Entry", "\(node.id)")
                info("Type", FileKind.guess(preview, name: node.name))
            }
            Section {
                Button("Copy path") { UIPasteboard.general.string = image.path(of: node.id) }
            }
            Section("First \(preview.count) bytes") {
                Text(hexDump(preview))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            preview = (try? image.read(offset: node.a, length: min(node.b, 256))) ?? Data()
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
