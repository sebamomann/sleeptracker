import Foundation

/// Nights on disk. One directory each, holding `session.json` and an `events/` folder.
///
/// Saved incrementally rather than only at stop: iOS can terminate a backgrounded app at
/// any point, and a night that cannot be read back afterwards is indistinguishable from a
/// night that never recorded.
final class SessionStore {
    static let shared = SessionStore()

    let root: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("nights", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func eventsDirectory(for id: String) -> URL {
        directory(for: id).appendingPathComponent("events", isDirectory: true)
    }
    func url(forEvent event: NightSession.EventRecord, in sessionID: String) -> URL {
        eventsDirectory(for: sessionID).appendingPathComponent(event.file)
    }

    func prepare(id: String) throws {
        try FileManager.default.createDirectory(at: eventsDirectory(for: id),
                                                withIntermediateDirectories: true)
    }

    func save(_ session: NightSession) throws {
        try prepare(id: session.id)
        let url = directory(for: session.id).appendingPathComponent("session.json")
        // Write to a sibling then move: a save interrupted by termination must not leave a
        // half-written JSON where a readable night used to be.
        let tmp = url.appendingPathExtension("tmp")
        try encoder.encode(session).write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    func load(id: String) -> NightSession? {
        let url = directory(for: id).appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(NightSession.self, from: data)
    }

    /// Newest first.
    func list() -> [NightSession] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap { load(id: $0) }.sorted { $0.t0 > $1.t0 }
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    func bytes(of id: String) -> Int64 {
        let dir = directory(for: id)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
