import Foundation
import Security
import CryptoKit

enum Keychain {
    private static let service = "com.rg.entertainment.account"

    static func set(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func remove(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The provider login lives in the iOS Keychain; everything else is scoped per login.
final class LocalStore {
    static let shared = LocalStore()

    let prefs = Prefs.named("library")
    private(set) var scope = "demo"

    private init() {}

    // MARK: account

    func saveAccount(_ credentials: Credentials) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: credentials.json(), options: []),
              Keychain.set(data, account: "provider") else {
            throw UserError("Could not save the account on this device.")
        }
        setScope(credentials)
    }

    func account() throws -> Credentials? {
        guard let data = Keychain.get(account: "provider") else { scope = "demo"; return nil }
        guard let o = Json.object(data) else { throw UserError("Saved login unreadable") }
        let c = try Credentials(server: Json.str(o, "server"), user: Json.str(o, "user"),
                                password: Json.str(o, "password"), allowHttp: Json.bool(o, "allowHttp"))
        setScope(c)
        return c
    }

    private func setScope(_ c: Credentials) {
        let digest = SHA256.hash(data: Data((c.server + "\n" + c.user).utf8))
        scope = digest.map { String(format: "%02x", $0) }.joined()
    }

    func logout() { Keychain.remove(account: "provider"); scope = "demo" }

    var navigationKey: String { return k("navigation/") }
    private func k(_ name: String) -> String { return scope + "/" + name }

    // MARK: favourites and groups

    func favourite(_ i: MediaItem) -> Bool { return prefs.contains(k("fav/" + i.key)) }

    func toggle(_ i: MediaItem) {
        let key = k("fav/" + i.key)
        if prefs.contains(key) { prefs.remove(key) } else { prefs.putString(key, i.jsonString()) }
    }

    func favourites() -> [MediaItem] { return items("fav/") }

    func favourites(group: String) -> [MediaItem] {
        var out = favourites()
        if !group.isEmpty {
            let members = prefs.set(k("group/" + group))
            out.removeAll { !members.contains($0.key) }
        }
        return orderedStations(out)
    }

    func groupNames() -> [String] {
        guard let stored = prefs.optionalString(k("groups")) else { return ["Everyday", "Sport", "Films"] }
        return Json.stringArray(stored)
    }

    private func saveGroupNames(_ names: [String]) { prefs.putString(k("groups"), Json.text(names)) }

    func createGroup(_ raw: String) -> Bool {
        let name = raw.trimmed
        var names = groupNames()
        if name.isEmpty || name.count > 32 || names.count >= 20 { return false }
        if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return false }
        names.append(name)
        saveGroupNames(names)
        return true
    }

    func renameGroup(_ old: String, _ raw: String) -> Bool {
        let name = raw.trimmed
        var names = groupNames()
        guard let at = names.firstIndex(of: old), !name.isEmpty, name.count <= 32 else { return false }
        if names.contains(where: { $0 != old && $0.caseInsensitiveCompare(name) == .orderedSame }) { return false }
        let members = prefs.set(k("group/" + old))
        names[at] = name
        prefs.remove(k("group/" + old))
        prefs.putSet(k("group/" + name), members)
        saveGroupNames(names)
        return true
    }

    func deleteGroup(_ name: String) {
        var names = groupNames()
        names.removeAll { $0 == name }
        prefs.remove(k("group/" + name))
        saveGroupNames(names)
    }

    func groups(of item: MediaItem) -> Set<String> {
        var result = Set<String>()
        for name in groupNames() where prefs.set(k("group/" + name)).contains(item.key) { result.insert(name) }
        return result
    }

    func setGroups(_ item: MediaItem, _ selected: Set<String>) {
        for name in groupNames() {
            var members = prefs.set(k("group/" + name))
            if selected.contains(name) { members.insert(item.key) } else { members.remove(item.key) }
            prefs.putSet(k("group/" + name), members)
        }
        if !selected.isEmpty { prefs.putString(k("fav/" + item.key), item.jsonString()) }
    }

    // MARK: ordering

    private func ranks(_ key: String) -> [String: Int] {
        var rank: [String: Int] = [:]
        for (n, id) in Json.stringArray(prefs.string(k(key), "[]")).enumerated() { rank[id] = n }
        return rank
    }

    func orderedStations(_ items: [MediaItem]) -> [MediaItem] {
        let rank = ranks("stationOrder")
        return items.stableSorted { $0.kind == .LIVE ? (rank[$0.id] ?? Int.max) : Int.max }
    }

    func stationOrder(_ items: [MediaItem]) {
        prefs.putString(k("stationOrder"), Json.text(items.filter { $0.kind == .LIVE }.map { $0.id }))
    }

    private func items(_ prefix: String) -> [MediaItem] {
        let start = k(prefix)
        var out: [MediaItem] = []
        for (key, value) in prefs.all() where key.hasPrefix(start) {
            if case .string(let text) = value, let item = MediaItem.from(text: text) { out.append(item) }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: watch progress

    func progress(_ item: MediaItem, position rawPosition: Int64, duration: Int64) {
        if item.kind == .LIVE || item.kind == .SERIES { return }
        let position = max(0, rawPosition)
        let id = item.key
        prefs.putLong(k("pos/" + id), position)
        prefs.putLong(k("time/" + id), nowMillis())
        if duration > 0 { prefs.putLong(k("duration/" + id), duration) }
        if duration > 0 && position >= duration - min(5000, duration / 10) {
            prefs.remove(k("recent/" + id))
            prefs.remove(k("pos/" + id))
            prefs.putBool(k("watched/" + id), true)
        } else if position > 0 {
            prefs.putString(k("recent/" + id), item.jsonString())
            prefs.remove(k("watched/" + id))
        }
        let list = recent()
        if list.count > 40 {
            for old in list[40...] {
                let key = old.key
                prefs.remove(k("recent/" + key)); prefs.remove(k("time/" + key))
                prefs.remove(k("pos/" + key)); prefs.remove(k("duration/" + key))
            }
        }
    }

    func position(_ item: MediaItem) -> Int64 { return item.kind == .LIVE ? 0 : prefs.long(k("pos/" + item.key), 0) }
    func duration(_ item: MediaItem) -> Int64 { return prefs.long(k("duration/" + item.key), 0) }
    func watched(_ item: MediaItem) -> Bool { return prefs.bool(k("watched/" + item.key), false) }

    func setWatched(_ item: MediaItem, _ value: Bool) {
        prefs.putBool(k("watched/" + item.key), value)
        prefs.remove(k("recent/" + item.key)); prefs.remove(k("pos/" + item.key)); prefs.remove(k("time/" + item.key))
    }

    func removeContinue(_ item: MediaItem) {
        prefs.remove(k("recent/" + item.key)); prefs.remove(k("time/" + item.key))
    }

    func recent() -> [MediaItem] {
        var out = items("recent/")
        out.removeAll { $0.kind == .LIVE || $0.kind == .SERIES || watched($0) }
        return out.sorted { prefs.long(k("time/" + $0.key), 0) > prefs.long(k("time/" + $1.key), 0) }
    }

    func clearHistory() {
        let prefixes = [k("recent/"), k("pos/"), k("time/"), k("duration/"), k("watched/")]
        prefs.removeAll { key in prefixes.contains { key.hasPrefix($0) } }
    }

    // MARK: browsing choices

    func saveBrowsingItems(_ kind: Kind, _ items: [MediaItem], _ hidden: Set<String>) {
        if kind == .LIVE { setHiddenStations(hidden); stationOrder(items); return }
        prefs.putSet(k("hiddenTitles/" + kind.rawValue), hidden)
        prefs.putString(k("itemOrder/" + kind.rawValue), Json.text(items.map { $0.id }))
    }

    func hiddenTitles(_ kind: Kind) -> Set<String> {
        return kind == .LIVE ? [] : prefs.set(k("hiddenTitles/" + kind.rawValue))
    }

    func orderedItems(_ kind: Kind, _ items: [MediaItem]) -> [MediaItem] {
        if kind == .LIVE { return orderedStations(items) }
        let rank = ranks("itemOrder/" + kind.rawValue)
        if rank.isEmpty { return items }
        return items.stableSorted { rank[$0.id] ?? Int.max }
    }

    func hiddenStations() -> Set<String> { return prefs.set(k("hiddenStations")) }
    func setHiddenStations(_ ids: Set<String>) { prefs.putSet(k("hiddenStations"), ids) }

    func ordered(_ kind: Kind, _ categories: [MediaCategory]) -> [MediaCategory] {
        let rank = ranks("order/" + kind.rawValue)
        return categories.stableSorted { $0.id.isEmpty ? -1 : (rank[$0.id] ?? Int.max) }
    }

    func order(_ kind: Kind, _ categories: [MediaCategory]) {
        prefs.putString(k("order/" + kind.rawValue), Json.text(categories.filter { !$0.id.isEmpty }.map { $0.id }))
    }

    var liveFormat: String {
        get { return prefs.string(k("liveFormat"), "m3u8") }
        set { prefs.putString(k("liveFormat"), newValue) }
    }

    func hidden(_ kind: Kind) -> Set<String> { return prefs.set(k("hidden/" + kind.rawValue)) }
    func setHidden(_ kind: Kind, _ ids: Set<String>) { prefs.putSet(k("hidden/" + kind.rawValue), ids) }

    func season(_ series: MediaItem) -> Int { return prefs.int(k("season/" + series.id), Int.min) }
    func setSeason(_ seriesId: String, _ number: Int) { prefs.putInt(k("season/" + seriesId), number) }

    // MARK: synopsis cache

    func synopsis(_ item: MediaItem) -> String? {
        let key = k("synopsis/" + item.key)
        let time = prefs.long(key + "/time", 0)
        if nowMillis() - time > 30 * 24 * 60 * 60 * 1000 { return nil }
        return prefs.optionalString(key)
    }

    func setSynopsis(_ item: MediaItem, _ plot: String) {
        let key = k("synopsis/" + item.key)
        prefs.putString(key, plot.count > 8000 ? String(plot.prefix(8000)) : plot)
        prefs.putLong(key + "/time", nowMillis())
        var keys = prefs.keys().filter { $0.contains("/synopsis/") && !$0.hasSuffix("/time") && $0 != key }
        if keys.count > 199 {
            keys.sort { prefs.long($0 + "/time", 0) < prefs.long($1 + "/time", 0) }
            for old in keys[0..<(keys.count - 199)] { prefs.remove(old); prefs.remove(old + "/time") }
        }
    }
}

// MARK: - Appearance

/// Device-wide appearance; preview palettes never change the saved theme.
struct Theme {
    static let blue: UInt32 = 0xff008cda
    static let pink: UInt32 = 0xffffd9e8
    static let yellow: UInt32 = 0xfffff1a6

    let base: UInt32
    let text: UInt32
    let panel: UInt32
    let active: UInt32
    let focus: UInt32
    let end: UInt32
    let muted: UInt32
    let black: Bool

    init(base raw: UInt32, black: Bool) {
        let b = raw | 0xff000000
        base = b
        self.black = black
        text = black ? 0xff101014 : 0xffffffff
        panel = Theme.tone(b, 0.94, 2.2)
        active = Theme.tone(b, 0.80, 3)
        focus = Theme.tone(b, 0.88, 2.8)
        end = Theme.tone(b, 0.98, 1.25)
        muted = black ? 0xff101014 : 0xffffffff
    }

    static func hsv(_ colour: UInt32) -> (h: Double, s: Double, v: Double) {
        let r = Double((colour >> 16) & 0xff) / 255, g = Double((colour >> 8) & 0xff) / 255, b = Double(colour & 0xff) / 255
        let mx = max(r, g, b), mn = min(r, g, b), delta = mx - mn
        var h = 0.0
        if delta > 0 {
            if mx == r { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if mx == g { h = 60 * ((b - r) / delta + 2) }
            else { h = 60 * ((r - g) / delta + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx == 0 ? 0 : delta / mx, mx)
    }

    static func colour(h: Double, s rawS: Double, v rawV: Double) -> UInt32 {
        let s = min(1, max(0, rawS)), v = min(1, max(0, rawV))
        let c = v * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch Int(hp) {
        case 0: r = c; g = x
        case 1: r = x; g = c
        case 2: g = c; b = x
        case 3: g = x; b = c
        case 4: r = x; b = c
        default: r = c; b = x
        }
        let m = v - c
        let ri = UInt32(((r + m) * 255).rounded()), gi = UInt32(((g + m) * 255).rounded()), bi = UInt32(((b + m) * 255).rounded())
        return 0xff000000 | (ri << 16) | (gi << 8) | bi
    }

    static func tone(_ colour: UInt32, _ value: Double, _ saturation: Double) -> UInt32 {
        let c = hsv(colour)
        return Theme.colour(h: c.h, s: min(1, c.s * saturation), v: c.v * value)
    }

    static func shade(_ colour: UInt32, _ brightness: Double) -> UInt32 {
        let c = hsv(colour)
        return Theme.colour(h: c.h, s: c.s, v: c.v * brightness)
    }

    static func read() -> Theme {
        let p = Prefs.named("appearance")
        return Theme(base: UInt32(truncatingIfNeeded: p.long("theme_colour", Int64(Theme.blue))),
                     black: p.bool("theme_black_text", false))
    }

    func save() {
        let p = Prefs.named("appearance")
        p.putLong("theme_colour", Int64(base))
        p.putBool("theme_black_text", black)
    }

    var key: String { return "\(base):\(black)" }
}

// MARK: - Main menu sections

/// Stable section IDs keep saved navigation compatible with renamed headings.
enum MainSections {
    static let ids = ["Live TV", "Films", "Series", "Favourites", "Continue", "Downloads", "My Music", "My Videos", "Settings"]
    private static var prefs: Prefs { return Prefs.named("main_sections") }

    static func title(_ id: String) -> String { return id }

    static func order() -> [String] {
        var out: [String] = []
        for id in Json.stringArray(prefs.string("order", "[]")) where ids.contains(id) && !out.contains(id) { out.append(id) }
        for id in ids where !out.contains(id) { out.append(id) }
        return out
    }

    static func hidden() -> Set<String> { return prefs.set("hidden").intersection(ids) }
    static func visible() -> [String] { let h = hidden(); return order().filter { !h.contains($0) } }
    static func first() -> String { return visible().first ?? "Settings" }
    static func enabled(_ id: String) -> Bool { return visible().contains(id) }
    static func revision() -> Int64 { return prefs.long("revision", 0) }

    static func save(order: [String], hidden: Set<String>) {
        var clean: [String] = []
        for id in order where ids.contains(id) && !clean.contains(id) { clean.append(id) }
        for id in ids where !clean.contains(id) { clean.append(id) }
        prefs.putString("order", Json.text(clean))
        prefs.putSet("hidden", hidden.intersection(ids))
        prefs.putLong("revision", revision() + 1)
    }
}

// MARK: - Profiles

/// Named on-device preference snapshots. Credentials, files and queues are never copied.
final class Profiles {
    private static let groups = ["appearance", "library", "main_sections", "subtitles"]
    private let file = Prefs.directory.appendingPathComponent("profiles.json")
    private let journal = Prefs.directory.appendingPathComponent("profiles-pending.json")

    private func scope() -> String {
        _ = try? LocalStore.shared.account()
        return LocalStore.shared.scope
    }

    private func allowed(_ group: String, _ key: String, _ scope: String) -> Bool {
        if group == "main_sections" { return key == "order" || key == "hidden" }
        if group == "library" { return key.hasPrefix(scope + "/") || key == "hidden_controls" }
        return group == "appearance" || group == "subtitles"
    }

    static func name(_ value: String) throws -> String {
        let n = value.trimmed
        if n.isEmpty || n.count > 32 || n.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw UserError("Use a profile name between 1 and 32 characters.")
        }
        return n
    }

    func list() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file), let raw = Json.array(data) else { return [] }
        return raw.compactMap { $0 as? [String: Any] }
    }

    private func write(_ url: URL, _ value: Any) throws {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []) else {
            throw UserError("Could not save profiles")
        }
        do { try data.write(to: url, options: .atomic) } catch { throw UserError("Could not save profiles") }
    }

    private func snapshot(_ scope: String) -> [String: Any] {
        var groups: [String: Any] = [:]
        for group in Profiles.groups {
            var entries: [String: Any] = [:]
            for (key, value) in Prefs.named(group).all() where allowed(group, key, scope) {
                switch value {
                case .set(let v): entries[key] = ["type": "set", "value": v] as [String: Any]
                case .bool(let v): entries[key] = ["type": "bool", "value": v] as [String: Any]
                case .int(let v): entries[key] = ["type": "long", "value": v] as [String: Any]
                case .double(let v): entries[key] = ["type": "float", "value": v] as [String: Any]
                case .string(let v): entries[key] = ["type": "string", "value": v] as [String: Any]
                }
            }
            groups[group] = entries
        }
        return ["scope": scope, "schema": 1, "groups": groups]
    }

    @discardableResult
    func save(_ rawTitle: String, replace: Bool) throws -> String {
        let title = try Profiles.name(rawTitle)
        var profiles = list()
        let existing = profiles.firstIndex { Json.str($0, "name").caseInsensitiveCompare(title) == .orderedSame }
        if existing != nil && !replace { throw UserError("That name is already saved. Choose Replace saved profile to update it.") }
        if existing == nil && profiles.count >= 20 { throw UserError("20 profiles are saved. Delete one before adding another.") }
        var entry: [String: Any] = existing.map { profiles[$0] } ?? ["id": UUID().uuidString]
        entry["name"] = title
        entry["saved"] = nowMillis()
        entry["snapshot"] = snapshot(scope())
        if let at = existing { profiles[at] = entry } else { profiles.append(entry) }
        try write(file, profiles)
        return Json.str(entry, "id")
    }

    func rename(_ id: String, _ rawTitle: String) throws {
        let title = try Profiles.name(rawTitle)
        var profiles = list()
        var found: Int?
        for (n, e) in profiles.enumerated() {
            if Json.str(e, "id") == id { found = n }
            else if Json.str(e, "name").caseInsensitiveCompare(title) == .orderedSame {
                throw UserError("Another profile already uses that name.")
            }
        }
        guard let at = found else { throw UserError("Profile not found.") }
        profiles[at]["name"] = title
        try write(file, profiles)
    }

    func delete(_ id: String) throws {
        try write(file, list().filter { Json.str($0, "id") != id })
    }

    private func values(_ snapshot: [String: Any], _ scope: String) throws -> [String: [String: PrefValue]] {
        guard Json.int(snapshot, "schema") == 1, Json.str(snapshot, "scope") == scope,
              let groups = snapshot["groups"] as? [String: Any] else {
            throw UserError("This profile belongs to a different provider login. Connect that login before loading it.")
        }
        var out: [String: [String: PrefValue]] = [:]
        for group in Profiles.groups {
            guard let entries = groups[group] as? [String: Any] else { continue }
            var parsed: [String: PrefValue] = [:]
            for (key, raw) in entries {
                guard allowed(group, key, scope), let e = raw as? [String: Any] else { throw UserError("Invalid profile setting") }
                switch Json.str(e, "type") {
                case "set": parsed[key] = .set((e["value"] as? [Any] ?? []).compactMap { $0 as? String })
                case "bool": parsed[key] = .bool(Json.bool(e, "value"))
                case "int", "long": parsed[key] = .int((e["value"] as? NSNumber)?.int64Value ?? 0)
                case "float": parsed[key] = .double((e["value"] as? NSNumber)?.doubleValue ?? 0)
                case "string": parsed[key] = .string(Json.str(e, "value"))
                default: throw UserError("Invalid profile setting")
                }
            }
            out[group] = parsed
        }
        return out
    }

    private func apply(_ snapshot: [String: Any], _ scope: String) throws {
        let groups = try values(snapshot, scope)
        for (group, entries) in groups {
            let prefs = Prefs.named(group)
            prefs.removeAll { self.allowed(group, $0, scope) }
            for (key, value) in entries { prefs.put(key, value) }
            prefs.flush()
        }
    }

    func load(_ id: String) throws {
        guard let selected = list().first(where: { Json.str($0, "id") == id }),
              let target = selected["snapshot"] as? [String: Any] else { throw UserError("Profile not found.") }
        let current = scope()
        _ = try values(target, current)
        let before = snapshot(current)
        try write(journal, before)
        do { try apply(target, current) } catch {
            try? apply(before, current)
            try? FileManager.default.removeItem(at: journal)
            throw UserError("Could not load the profile. Previous settings will be restored when the app opens.")
        }
        try? FileManager.default.removeItem(at: journal)
        let state = Prefs.named("profile_state")
        state.putLong("revision", state.long("revision", 0) + 1)
    }

    func recover() throws {
        guard let data = try? Data(contentsOf: journal) else { return }
        guard let old = Json.object(data) else { try? FileManager.default.removeItem(at: journal); return }
        try apply(old, scope())
        try? FileManager.default.removeItem(at: journal)
    }

    static func revision() -> Int64 { return Prefs.named("profile_state").long("revision", 0) }
}
