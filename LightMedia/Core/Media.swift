import Foundation

enum Kind: String {
    case LIVE, MOVIE, SERIES, EPISODE
}

/// Provider-independent, credential-free catalogue models.
struct MediaItem: Equatable {
    let kind: Kind
    let id: String
    let name: String
    let category: String
    let image: String
    let plot: String
    let ext: String
    let seriesId: String
    var seasonNumber: Int = -1
    var episodeNumber: Int = -1

    var key: String { return kind.rawValue + ":" + id }

    func json() -> [String: Any] {
        return ["kind": kind.rawValue, "id": id, "name": name, "category": category, "image": image,
                "plot": plot, "extension": ext, "seriesId": seriesId,
                "seasonNumber": seasonNumber, "episodeNumber": episodeNumber]
    }

    func jsonString() -> String { return Json.text(json()) }

    static func from(_ o: [String: Any]) -> MediaItem? {
        guard let kind = Kind(rawValue: Json.str(o, "kind")) else { return nil }
        return MediaItem(kind: kind, id: Json.str(o, "id"), name: Json.str(o, "name"),
                         category: Json.str(o, "category"), image: Json.str(o, "image"),
                         plot: Json.str(o, "plot"), ext: Json.str(o, "extension", "mp4"),
                         seriesId: Json.str(o, "seriesId"),
                         seasonNumber: Json.int(o, "seasonNumber", -1),
                         episodeNumber: Json.int(o, "episodeNumber", -1))
    }

    static func from(text: String) -> MediaItem? {
        guard let o = Json.object(text) else { return nil }
        return from(o)
    }
}

struct MediaCategory: Equatable {
    let id: String
    let name: String
}

enum Media {
    static func clean(_ o: [String: Any], _ key: String) -> String { return Json.str(o, key) }

    static func parseCatalogue(_ array: [Any], _ kind: Kind) -> [MediaItem] {
        var out: [MediaItem] = []
        out.reserveCapacity(array.count)
        for raw in array {
            guard let o = raw as? [String: Any] else { continue }
            let id = clean(o, kind == .SERIES ? "series_id" : "stream_id")
            let name = clean(o, "name")
            if id.isEmpty || name.isEmpty { continue }
            out.append(MediaItem(kind: kind, id: id, name: name, category: clean(o, "category_id"),
                                 image: clean(o, kind == .SERIES ? "cover" : "stream_icon"),
                                 plot: clean(o, "plot"), ext: clean(o, "container_extension"), seriesId: ""))
        }
        return out
    }

    private static func strip(_ text: String, _ pattern: String) -> String {
        if let range = text.range(of: pattern, options: [.regularExpression, .anchored]) {
            return String(text[range.upperBound...])
        }
        return text
    }

    static func parseEpisodes(_ response: [String: Any], _ series: MediaItem) -> [Int: [MediaItem]] {
        var out: [Int: [MediaItem]] = [:]
        guard let seasons = response["episodes"] as? [String: Any] else { return out }
        for (key, value) in seasons {
            guard let number = Int(key), let raw = value as? [Any] else { continue }
            let rows = raw.compactMap { $0 as? [String: Any] }
                .stableSorted { Json.int($0, "episode_num", 0) }
            var items: [MediaItem] = []
            for o in rows {
                let id = clean(o, "id")
                if id.isEmpty { continue }
                let info = o["info"] as? [String: Any]
                var title = clean(o, "title")
                if title.isEmpty { title = "Episode \(Json.int(o, "episode_num", items.count + 1))" }
                var image = info.map { clean($0, "movie_image") } ?? series.image
                if image.isEmpty { image = series.image }
                if !series.name.isEmpty && title.hasPrefix(series.name) {
                    title = strip(String(title.dropFirst(series.name.count)), "[\\s·:–—-]+")
                }
                title = strip(title, "(?i)S\\d+\\s*E\\d+[\\s·:–—-]*")
                var plot = info.map { clean($0, "plot") } ?? ""
                if plot.isEmpty { plot = clean(o, "plot") }
                items.append(MediaItem(kind: .EPISODE, id: id, name: title, category: series.category,
                                       image: image, plot: plot, ext: clean(o, "container_extension"),
                                       seriesId: series.id, seasonNumber: number,
                                       episodeNumber: Json.int(o, "episode_num", items.count + 1)))
            }
            if !items.isEmpty { out[number] = items }
        }
        return out
    }

    static func episodeLabel(_ item: MediaItem) -> String {
        if item.episodeNumber >= 0 {
            return String(format: "S%02d · E%02d — %@", item.seasonNumber, item.episodeNumber, item.name)
        }
        return item.name
    }

    static func nextEpisode(_ seasons: [Int: [MediaItem]], _ current: MediaItem) -> MediaItem? {
        var found = false
        for number in seasons.keys.sorted() {
            for item in seasons[number] ?? [] {
                if found { return item }
                if item.id == current.id { found = true }
            }
        }
        return nil
    }
}

/// Fictional catalogue used until a provider is connected.
enum Demo {
    static func catalogue(_ kind: Kind) -> [MediaItem] {
        let names: [String]
        switch kind {
        case .LIVE: names = ["RG One", "RG Cinema", "RG Explore", "RG Sport", "RG Stories", "RG Junior"]
        case .MOVIE: names = ["Beyond the Blue", "Night Drive", "The Long Way Home", "Wild Coast",
                              "Northern Lights", "A Summer Somewhere", "Orbit", "After the Rain"]
        default: names = ["The Night Shift", "Coastlines", "The Last Signal", "Weekend Away", "Open Roads", "City Stories"]
        }
        var out: [MediaItem] = []
        for (i, name) in names.enumerated() {
            out.append(MediaItem(kind: kind, id: "demo-\(kind.rawValue)-\(i)", name: name,
                                 category: i % 2 == 0 ? "1" : "2", image: "",
                                 plot: "A fictional title for exploring Light Media. Play opens the bundled motion test clip; no subscription is needed.",
                                 ext: "mp4", seriesId: ""))
        }
        return out
    }

    static func categories() -> [MediaCategory] {
        return [MediaCategory(id: "", name: "All categories"),
                MediaCategory(id: "1", name: "Drama & discovery"),
                MediaCategory(id: "2", name: "Entertainment")]
    }

    static func episodes(_ series: MediaItem) -> [Int: [MediaItem]] {
        var out: [Int: [MediaItem]] = [:]
        for season in 1...3 {
            var items: [MediaItem] = []
            for e in 1...6 {
                items.append(MediaItem(kind: .EPISODE, id: "\(series.id)-\(season)-\(e)",
                                       name: "S\(season) · Episode \(e)", category: "", image: "",
                                       plot: "Demo episode · 12-second motion test clip.", ext: "mp4",
                                       seriesId: series.id))
            }
            out[season] = items
        }
        return out
    }
}

/// Live channel list shared between the browser and the full-screen player.
enum LiveChannels {
    static func visible(_ source: [MediaItem], _ store: LocalStore, _ category: String,
                        _ query: String, _ current: MediaItem?) -> [MediaItem] {
        let hidden = store.hidden(.LIVE), stations = store.hiddenStations()
        let needle = query.lowercased()
        var order: [String] = []
        var unique: [String: MediaItem] = [:]
        for i in source where i.kind == .LIVE && !hidden.contains(i.category) && !stations.contains(i.id)
            && (category.isEmpty || category == i.category)
            && (needle.isEmpty || i.name.lowercased().contains(needle)) {
            if unique[i.id] == nil { order.append(i.id) }
            unique[i.id] = i
        }
        // An explicitly opened favourite may have since been hidden; keep that channel
        // playable, without reintroducing other hidden channels into the switching list.
        if let current = current, unique[current.id] == nil {
            order.append(current.id)
            unique[current.id] = current
        }
        return store.orderedStations(order.compactMap { unique[$0] })
    }

    static func index(_ channels: [MediaItem], _ current: MediaItem) -> Int {
        return channels.firstIndex { $0.id == current.id } ?? 0
    }

    static func step(_ channels: [MediaItem], _ current: MediaItem, _ delta: Int) -> MediaItem {
        if channels.isEmpty { return current }
        return channels[floorMod(index(channels, current) + delta, channels.count)]
    }
}
