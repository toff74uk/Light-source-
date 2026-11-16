import Foundation

/// One typed value, so profile snapshots can restore exactly what was saved.
enum PrefValue: Codable, Equatable {
    case string(String), bool(Bool), int(Int64), double(Double), set([String])

    private enum Keys: String, CodingKey { case t, v }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .t)
        switch type {
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .v))
        case "int": self = .int(try c.decode(Int64.self, forKey: .v))
        case "double": self = .double(try c.decode(Double.self, forKey: .v))
        case "set": self = .set(try c.decode([String].self, forKey: .v))
        default: self = .string(try c.decode(String.self, forKey: .v))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .string(let v): try c.encode("string", forKey: .t); try c.encode(v, forKey: .v)
        case .bool(let v): try c.encode("bool", forKey: .t); try c.encode(v, forKey: .v)
        case .int(let v): try c.encode("int", forKey: .t); try c.encode(v, forKey: .v)
        case .double(let v): try c.encode("double", forKey: .t); try c.encode(v, forKey: .v)
        case .set(let v): try c.encode("set", forKey: .t); try c.encode(v, forKey: .v)
        }
    }
}

/// Named preference groups, the iOS counterpart of Android SharedPreferences.
/// Each group is one small JSON file in Application Support.
final class Prefs {
    private static var cache: [String: Prefs] = [:]
    private static let cacheLock = NSLock()

    static func named(_ name: String) -> Prefs {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let existing = cache[name] { return existing }
        let created = Prefs(name: name)
        cache[name] = created
        return created
    }

    static func flushAll() {
        cacheLock.lock(); let all = Array(cache.values); cacheLock.unlock()
        for p in all { p.flush() }
    }

    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LightMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    let name: String
    private var values: [String: PrefValue] = [:]
    private let url: URL
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "lightmedia.prefs")
    private var writePending = false

    private init(name: String) {
        self.name = name
        url = Prefs.directory.appendingPathComponent("prefs-" + name + ".json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: PrefValue].self, from: data) {
            values = decoded
        }
    }

    // MARK: reading

    func contains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[key] != nil }
    func value(_ key: String) -> PrefValue? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func all() -> [String: PrefValue] { lock.lock(); defer { lock.unlock() }; return values }
    func keys() -> [String] { lock.lock(); defer { lock.unlock() }; return Array(values.keys) }

    func string(_ key: String, _ fallback: String = "") -> String {
        if case .string(let v)? = value(key) { return v }
        return fallback
    }
    func optionalString(_ key: String) -> String? {
        if case .string(let v)? = value(key) { return v }
        return nil
    }
    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        if case .bool(let v)? = value(key) { return v }
        return fallback
    }
    func int(_ key: String, _ fallback: Int = 0) -> Int {
        switch value(key) {
        case .int(let v)?: return Int(v)
        case .double(let v)?: return Int(v)
        default: return fallback
        }
    }
    func long(_ key: String, _ fallback: Int64 = 0) -> Int64 {
        switch value(key) {
        case .int(let v)?: return v
        case .double(let v)?: return Int64(v)
        default: return fallback
        }
    }
    func set(_ key: String) -> Set<String> {
        if case .set(let v)? = value(key) { return Set(v) }
        return []
    }

    // MARK: writing

    func put(_ key: String, _ value: PrefValue) {
        lock.lock(); values[key] = value; lock.unlock(); changed()
    }
    func putString(_ key: String, _ v: String) { put(key, .string(v)) }
    func putBool(_ key: String, _ v: Bool) { put(key, .bool(v)) }
    func putInt(_ key: String, _ v: Int) { put(key, .int(Int64(v))) }
    func putLong(_ key: String, _ v: Int64) { put(key, .int(v)) }
    func putSet(_ key: String, _ v: Set<String>) { put(key, .set(Array(v).sorted())) }
    func remove(_ key: String) {
        lock.lock(); values.removeValue(forKey: key); lock.unlock(); changed()
    }
    func removeAll(where predicate: (String) -> Bool) {
        lock.lock()
        for key in Array(values.keys) where predicate(key) { values.removeValue(forKey: key) }
        lock.unlock(); changed()
    }

    private func changed() {
        lock.lock()
        let schedule = !writePending
        writePending = true
        lock.unlock()
        if schedule {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.flush() }
        }
    }

    func flush() {
        lock.lock()
        let snapshot = values
        writePending = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Small helpers shared by the data layer

enum Json {
    static func object(_ data: Data) -> [String: Any]? {
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }
    static func array(_ data: Data) -> [Any]? {
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any]
    }
    static func object(_ text: String) -> [String: Any]? { return object(Data(text.utf8)) }
    static func stringArray(_ text: String) -> [String] {
        guard let raw = array(Data(text.utf8)) else { return [] }
        return raw.compactMap { $0 as? String }
    }
    static func text(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    /// Android's optString: numbers become text, null and missing become the fallback.
    static func str(_ o: [String: Any], _ key: String, _ fallback: String = "") -> String {
        guard let v = o[key], !(v is NSNull) else { return fallback }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return fallback
    }
    static func int(_ o: [String: Any], _ key: String, _ fallback: Int = 0) -> Int {
        guard let v = o[key], !(v is NSNull) else { return fallback }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String {
            if let i = Int(s) { return i }
            if let d = Double(s) { return Int(d) }
        }
        return fallback
    }
    static func bool(_ o: [String: Any], _ key: String, _ fallback: Bool = false) -> Bool {
        guard let v = o[key], !(v is NSNull) else { return fallback }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s.lowercased() == "true" }
        return fallback
    }
}

extension String {
    /// Same result as Java's String.hashCode, used for stable placeholder colours and demo data.
    var javaHash: Int32 {
        var h: Int32 = 0
        for unit in utf16 { h = 31 &* h &+ Int32(unit) }
        return h
    }
    var trimmed: String { return trimmingCharacters(in: .whitespacesAndNewlines) }
}

func floorMod(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return r < 0 ? r + b : r
}

func nowMillis() -> Int64 { return Int64(Date().timeIntervalSince1970 * 1000) }

extension Array {
    /// Stable ordering by an integer rank, matching Java's List.sort.
    func stableSorted(by rank: (Element) -> Int) -> [Element] {
        return enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.element }
    }
}
