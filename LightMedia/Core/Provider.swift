import Foundation

struct ProviderFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { return message }
}

struct UserError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { return message }
}

struct Credentials {
    let server: String
    let user: String
    let password: String
    let allowHttp: Bool

    init(server: String, user: String, password: String, allowHttp: Bool) throws {
        self.server = try Provider.normaliseServer(server)
        self.user = user.trimmed
        self.password = password
        self.allowHttp = allowHttp
        if self.user.isEmpty || password.isEmpty { throw UserError("Enter your username and password.") }
        if self.server.hasPrefix("http:") && !allowHttp {
            throw UserError("This server uses HTTP. Tick the HTTP option if your provider requires it.")
        }
    }

    func json() -> [String: Any] {
        return ["server": server, "user": user, "password": password, "allowHttp": allowHttp]
    }
}

/// Refuses redirects, as the Android app does, so a login is never forwarded to another host.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum Http {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
}

/// Common Xtream-compatible API. No request URL, credentials or response body is logged.
final class Provider {
    let credentials: Credentials
    init(_ credentials: Credentials) { self.credentials = credentials }

    static func normaliseServer(_ input: String) throws -> String {
        let failure = UserError("Enter the server address only, including its port if supplied. Do not paste a playlist link.")
        var value = input.trimmed
        if !value.contains("://") { value = "https://" + value }
        guard let c = URLComponents(string: value), let scheme = c.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { throw failure }
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/player_api.php") { path = String(path.dropLast(15)) }
        if path.hasSuffix(".php") { throw failure }
        var authority = host
        if let port = c.port { authority += ":\(port)" }
        return scheme + "://" + authority + path
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.*")

    static func encode(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    func apiUrl(_ action: String, _ parameters: [String] = []) -> String {
        var s = credentials.server + "/player_api.php?username=" + Provider.encode(credentials.user)
            + "&password=" + Provider.encode(credentials.password)
        if !action.isEmpty { s += "&action=" + Provider.encode(action) }
        var i = 0
        while i + 1 < parameters.count {
            s += "&" + Provider.encode(parameters[i]) + "=" + Provider.encode(parameters[i + 1])
            i += 2
        }
        return s
    }

    func streamUrl(_ item: MediaItem, liveFormat: String) -> String {
        let type = item.kind == .LIVE ? "live" : item.kind == .MOVIE ? "movie" : "series"
        var ext = item.kind == .LIVE ? liveFormat : item.ext
        if ext.range(of: "^[A-Za-z0-9]{1,10}$", options: .regularExpression) == nil {
            ext = item.kind == .LIVE ? "ts" : "mp4"
        }
        return credentials.server + "/" + type + "/" + Provider.encode(credentials.user) + "/"
            + Provider.encode(credentials.password) + "/" + Provider.encode(item.id) + "." + ext
    }

    func request(_ action: String, _ parameters: [String] = []) async throws -> Data {
        guard let url = URL(string: apiUrl(action, parameters)) else {
            throw ProviderFailure("The connection to your provider failed. Check the server address and try again.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("RGEntertainment/0.1", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Http.session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw ProviderFailure("The provider took too long to respond. Check your connection and retry.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
                throw ProviderFailure("The provider's secure connection could not be verified. Check its server address.")
            case .cannotFindHost, .dnsLookupFailed:
                throw ProviderFailure("The server could not be found. Check its address and your internet connection.")
            default:
                throw ProviderFailure("The connection to your provider failed. Check the server address and try again.")
            }
        } catch {
            throw ProviderFailure("The connection to your provider failed. Check the server address and try again.")
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw ProviderFailure("The provider rejected the login. Check your account details.") }
        if code >= 300 && code < 400 { throw ProviderFailure("The provider redirects this address. Use its final server address from your provider.") }
        if code != 200 { throw ProviderFailure("The provider returned HTTP \(code). Try again shortly.") }
        if data.count > 32 * 1024 * 1024 { throw ProviderFailure("This catalogue is too large. Choose a smaller category.") }
        return data
    }

    private func object(_ action: String, _ parameters: [String] = []) async throws -> [String: Any] {
        guard let o = Json.object(try await request(action, parameters)) else { throw UnexpectedResponse() }
        return o
    }

    private func array(_ action: String, _ parameters: [String] = []) async throws -> [Any] {
        guard let a = Json.array(try await request(action, parameters)) else { throw UnexpectedResponse() }
        return a
    }

    func authenticate() async throws {
        let root = try await object("")
        guard let info = root["user_info"] as? [String: Any], Json.int(info, "auth", 0) == 1 else {
            throw ProviderFailure("The provider rejected the username or password.")
        }
        if Json.str(info, "status", "Active").lowercased() != "active" {
            throw ProviderFailure("Your provider account is not active. Check it with your provider.")
        }
    }

    func categories(_ kind: Kind) async throws -> [MediaCategory] {
        let action = kind == .LIVE ? "get_live_categories" : kind == .MOVIE ? "get_vod_categories" : "get_series_categories"
        var out = [MediaCategory(id: "", name: "All categories")]
        for raw in try await array(action) {
            if let o = raw as? [String: Any] {
                out.append(MediaCategory(id: Json.str(o, "category_id"), name: Json.str(o, "category_name", "Other")))
            }
        }
        return out
    }

    func catalogue(_ kind: Kind, _ category: String) async throws -> [MediaItem] {
        let action = kind == .LIVE ? "get_live_streams" : kind == .MOVIE ? "get_vod_streams" : "get_series"
        let parameters: [String] = category.isEmpty ? [] : ["category_id", category]
        let rows = try await array(action, parameters)
        return Media.parseCatalogue(rows, kind)
    }

    func seriesInfo(_ series: MediaItem) async throws -> [String: Any] {
        return try await object("get_series_info", ["series_id", series.id])
    }

    func episodes(_ series: MediaItem) async throws -> [Int: [MediaItem]] {
        return Media.parseEpisodes(try await seriesInfo(series), series)
    }

    func moviePlot(_ item: MediaItem) async throws -> String {
        let root = try await object("get_vod_info", ["vod_id", item.id])
        guard let info = root["info"] as? [String: Any] else { return "" }
        return Media.clean(info, "plot")
    }

    func programmes(_ channel: MediaItem) async throws -> [Programme] {
        return Epg.parse(try await object("get_short_epg", ["stream_id", channel.id, "limit", "12"]))
    }

    func guide(_ channel: MediaItem) async throws -> String {
        let root = try await object("get_short_epg", ["stream_id", channel.id, "limit", "5"])
        guard let list = root["epg_listings"] as? [Any], !list.isEmpty else {
            return "No programme information supplied for this channel."
        }
        let format = DateFormatter()
        format.dateFormat = "EEE HH:mm"
        var lines: [String] = []
        for raw in list {
            guard let o = raw as? [String: Any] else { continue }
            var start = Json.str(o, "start")
            let stamp = Double(Json.str(o, "start_timestamp", "0")) ?? 0
            if stamp > 0 { start = format.string(from: Date(timeIntervalSince1970: stamp)) }
            lines.append(start + "   " + Provider.decode(Json.str(o, "title", "Programme")))
        }
        return lines.joined(separator: "\n\n")
    }

    /// Xtream guide text is usually base64; fall back to the raw text when it is not.
    static func decode(_ value: String) -> String {
        guard let data = Data(base64Encoded: value), let text = String(data: data, encoding: .utf8) else { return value }
        return text
    }
}

struct UnexpectedResponse: Error {}

func safeError(_ error: Error) -> String {
    if let failure = error as? ProviderFailure { return failure.message }
    return "The provider returned an unexpected response. Check the account details and try again."
}

// MARK: - Programme guide

/// Provider programme times normalised to UTC milliseconds; display uses the device time zone.
struct Programme: Equatable {
    let start: Int64
    let end: Int64
    let title: String
    let description: String

    func overlaps(_ from: Int64, _ to: Int64) -> Bool { return start < to && end > from }

    func times() -> String {
        return Epg.clock.string(from: Date(timeIntervalSince1970: Double(start) / 1000)) + " – "
            + Epg.clock.string(from: Date(timeIntervalSince1970: Double(end) / 1000))
    }
}

enum Epg {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let patterns: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXX"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        f.isLenient = false
        return f
    }

    static func parse(_ data: [String: Any]) -> [Programme] {
        guard let rows = data["epg_listings"] as? [Any] else { return [] }
        var out: [Programme] = []
        for raw in rows {
            guard let row = raw as? [String: Any] else { continue }
            let start = time(row, "start_timestamp", "start")
            var end = time(row, "stop_timestamp", "end")
            if end == 0 { end = time(row, "end_timestamp", "stop") }
            if start <= 0 || end <= start || end - start > 7 * 24 * 3_600_000 { continue }
            let title = Provider.decode(Json.str(row, "title", "Programme"))
            let desc = Provider.decode(Json.str(row, "description"))
            out.append(Programme(start: start, end: end, title: clean(title, 180), description: clean(desc, 4000)))
        }
        return out.sorted { $0.start < $1.start }
    }

    static func time(_ row: [String: Any], _ stamp: String, _ text: String) -> Int64 {
        if let value = Double(Json.str(row, stamp, "0")), value.isFinite, value > 0 {
            return Int64(value < 100_000_000_000 ? value * 1000 : value)
        }
        let raw = Json.str(row, text)
        for format in patterns {
            if let date = format.date(from: raw) { return Int64(date.timeIntervalSince1970 * 1000) }
        }
        return 0
    }

    static func clean(_ s: String, _ limit: Int) -> String {
        var value = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        value = String(value.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }.map { Character($0) })
        value = value.trimmed
        return value.count > limit ? String(value.prefix(limit)) : value
    }

    static func demo(_ channel: MediaItem, _ now: Int64) -> [Programme] {
        let half: Int64 = 30 * 60_000
        let base = now - now % half
        let names = ["RG motion test", "Studio stories", "The evening edit", "Coast to coast", "After hours", "Weekend preview"]
        var list: [Programme] = []
        for i in -1..<12 {
            let start = base + Int64(i) * half
            let name = names[floorMod(i + Int(channel.id.javaHash), names.count)]
            list.append(Programme(start: start, end: start + half, title: name,
                                  description: "Fictional demo programme. Watch channel plays the bundled motion test clip."))
        }
        return list
    }
}
