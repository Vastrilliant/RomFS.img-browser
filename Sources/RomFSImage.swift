import Foundation

struct RomFSNode: Identifiable, Hashable {
    let id: Int
    let name: String
    let isDirectory: Bool
    let a: UInt64
    let b: UInt64
}

enum RomFSError: LocalizedError {
    case notAnImage
    case invalidIndex(String)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notAnImage: return "This file does not start with the DMROMFS1 magic, so it is not a RomFS image."
        case .invalidIndex(let reason): return "The image index is invalid: \(reason)."
        case .unreadable: return "The file could not be read."
        }
    }
}

final class RomFSImage: @unchecked Sendable {
    static let headerSize = 32
    static let entrySize = 24

    let url: URL
    let fileSize: UInt64
    let count: Int
    let fileCount: Int
    let totalFileBytes: UInt64
    private let index: Data
    private let poolStart: Int
    private let parents: [Int32]

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: Self.headerSize), head.count == Self.headerSize else {
            throw RomFSError.notAnImage
        }
        let header = Data(head)
        guard header.prefix(8) == Data("DMROMFS1".utf8) else { throw RomFSError.notAnImage }
        let indexOffset = Self.u64(header, 8)
        let indexSize = Self.u64(header, 16)
        let entryCount = Self.u64(header, 24)
        guard indexOffset >= UInt64(Self.headerSize), indexOffset <= size else {
            throw RomFSError.invalidIndex("index offset is outside the file")
        }
        guard indexSize == size - indexOffset else {
            throw RomFSError.invalidIndex("index does not end at the end of the file, the copy may be cut off")
        }
        guard entryCount > 0, entryCount <= UInt64(UInt32.max), entryCount * UInt64(Self.entrySize) <= indexSize else {
            throw RomFSError.invalidIndex("entry count does not fit the index")
        }
        guard indexSize <= 1 << 30 else { throw RomFSError.invalidIndex("index is larger than 1 GB") }
        try handle.seek(toOffset: indexOffset)
        guard let raw = try handle.read(upToCount: Int(indexSize)), raw.count == Int(indexSize) else {
            throw RomFSError.unreadable
        }
        let data = Data(raw)
        let n = Int(entryCount)
        var parentTable = [Int32](repeating: -1, count: n)
        var total: UInt64 = 0
        var files = 0
        data.withUnsafeBytes { buf in
            for k in 0..<n {
                let base = k * Self.entrySize
                let a = buf.loadUnaligned(fromByteOffset: base, as: UInt64.self)
                let b = buf.loadUnaligned(fromByteOffset: base + 8, as: UInt64.self)
                if buf[base + 22] == 0 {
                    if a < UInt64(n), b <= UInt64(n) - a, b > 0 {
                        for c in Int(a)..<Int(a + b) { parentTable[c] = Int32(k) }
                    }
                } else {
                    total &+= b
                    files += 1
                }
            }
        }
        self.url = url
        self.fileSize = size
        self.count = n
        self.fileCount = files
        self.totalFileBytes = total
        self.index = data
        self.poolStart = n * Self.entrySize
        self.parents = parentTable
    }

    private static func u64(_ d: Data, _ offset: Int) -> UInt64 {
        d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    }

    private func raw(_ k: Int) -> (a: UInt64, b: UInt64, nameOffset: Int, nameLength: Int, isDirectory: Bool)? {
        guard k >= 0, k < count else { return nil }
        return index.withUnsafeBytes { buf in
            let base = k * Self.entrySize
            return (
                buf.loadUnaligned(fromByteOffset: base, as: UInt64.self),
                buf.loadUnaligned(fromByteOffset: base + 8, as: UInt64.self),
                Int(buf.loadUnaligned(fromByteOffset: base + 16, as: UInt32.self)),
                Int(buf.loadUnaligned(fromByteOffset: base + 20, as: UInt16.self)),
                buf[base + 22] == 0
            )
        }
    }

    func name(of k: Int) -> String {
        guard let e = raw(k) else { return "" }
        let start = poolStart + e.nameOffset
        let end = start + e.nameLength
        guard end <= index.count else { return "?" }
        return String(decoding: index[(index.startIndex + start)..<(index.startIndex + end)], as: UTF8.self)
    }

    func node(_ k: Int) -> RomFSNode? {
        guard let e = raw(k) else { return nil }
        return RomFSNode(id: k, name: k == 0 ? "/" : name(of: k), isDirectory: e.isDirectory, a: e.a, b: e.b)
    }

    var root: RomFSNode { node(0) ?? RomFSNode(id: 0, name: "/", isDirectory: true, a: 0, b: 0) }

    func childRange(of k: Int) -> Range<Int> {
        guard let e = raw(k), e.isDirectory, e.a < UInt64(count), e.b <= UInt64(count) - e.a else { return 0..<0 }
        return Int(e.a)..<Int(e.a + e.b)
    }

    func path(of k: Int) -> String {
        var parts: [String] = []
        var cur = k
        var guardCount = 0
        while cur > 0, guardCount < 4096 {
            parts.append(name(of: cur))
            let p = parents[cur]
            if p < 0 { break }
            cur = Int(p)
            guardCount += 1
        }
        return "/" + parts.reversed().joined(separator: "/")
    }

    func search(_ query: String, limit: Int = 500) -> [RomFSNode] {
        let q = query.lowercased()
        guard !q.isEmpty, count > 1 else { return [] }
        var out: [RomFSNode] = []
        for k in 1..<count {
            if name(of: k).lowercased().contains(q), let n = node(k) {
                out.append(n)
                if out.count >= limit { break }
            }
        }
        return out
    }

    func read(offset: UInt64, length: UInt64) throws -> Data {
        guard offset <= fileSize, length <= fileSize - offset else { throw RomFSError.unreadable }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return Data(try handle.read(upToCount: Int(length)) ?? Data())
    }
}

enum FileKind {
    static func guess(_ data: Data, name: String) -> String {
        let p = [UInt8](data.prefix(16))
        func starts(_ s: String) -> Bool { p.starts(with: Array(s.utf8)) }
        if starts("UnityFS") { return "Unity asset bundle (UnityFS)" }
        if starts("UnityWeb") || starts("UnityRaw") { return "Unity asset bundle (legacy)" }
        if p.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG image" }
        if p.starts(with: [0xFF, 0xD8, 0xFF]) { return "JPEG image" }
        if starts("DDS ") { return "DDS texture" }
        if starts("RIFF") { return "RIFF container (WAV or similar)" }
        if starts("OggS") { return "Ogg audio" }
        if starts("MZ") { return "Windows PE (DLL or EXE)" }
        if starts("NSO0") { return "NSO executable" }
        if starts("NRO0") { return "NRO module" }
        if starts("SARC") { return "SARC archive" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "json": return "JSON text"
        case "dat": return "Data file"
        case "assets", "resource", "ress": return "Unity serialized or resource data"
        case "bundle": return "Addressables bundle"
        case "": return "Unknown"
        default: return "Unknown (.\(ext))"
        }
    }
}

func hexDump(_ data: Data) -> String {
    let bytes = [UInt8](data)
    var lines: [String] = []
    var i = 0
    while i < bytes.count {
        let chunk = bytes[i..<min(i + 16, bytes.count)]
        let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
        let pad = String(repeating: "   ", count: 16 - chunk.count)
        let ascii = String(chunk.map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
        lines.append(String(format: "%08x  ", i) + hex + pad + " " + ascii)
        i += 16
    }
    return lines.joined(separator: "\n")
}

func formatBytes(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
}
