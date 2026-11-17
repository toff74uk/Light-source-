import UIKit

enum MediaServers {
    static let changed = Notification.Name("LightMediaServersChanged")
    private static var file: URL { Prefs.directory.appendingPathComponent("media-servers.json") }
    static func all() -> [UPnPServer] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([UPnPServer].self, from: data)) ?? []
    }
    static func save(_ servers: [UPnPServer]) throws {
        try JSONEncoder().encode(servers).write(to: file, options: .atomic)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func add(_ server: UPnPServer) throws {
        var servers = all()
        servers.removeAll { $0.id == server.id || $0.descriptionURL == server.descriptionURL }
        servers.append(server)
        try save(servers)
    }
}

/// Shared compact rows, sized for landscape iPhone and the current Light theme.
class MediaListView: UIView, UITableViewDataSource, UITableViewDelegate {
    struct Row {
        let title: String
        let subtitle: String
        let icon: String
        let action: () -> Void
        var options: (() -> Void)? = nil
    }
    let table = UITableView(frame: .zero, style: .plain)
    let hint = Ui.label("", 13, Ui.muted, lines: 2)
    var buttons: [LMButton] = []
    var rows: [Row] = [] { didSet { table.reloadData() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        table.backgroundColor = .clear
        table.separatorColor = Ui.muted.withAlphaComponent(0.15)
        table.rowHeight = 58
        table.dataSource = self
        table.delegate = self
        table.tableFooterView = UIView()
        table.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        addSubview(table)
        addSubview(hint)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func toolbar(_ buttons: [LMButton]) {
        self.buttons.forEach { $0.removeFromSuperview() }
        self.buttons = buttons
        buttons.forEach { addSubview($0) }
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, (bounds.width - CGFloat(max(0, buttons.count - 1)) * Ui.gap) / CGFloat(max(1, buttons.count)))
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * (width + Ui.gap), y: 0, width: width, height: 38)
        }
        let y: CGFloat = buttons.isEmpty ? 0 : 42
        hint.frame = CGRect(x: 6, y: y, width: max(0, bounds.width - 12), height: 34)
        table.frame = CGRect(x: 0, y: y + 36, width: bounds.width, height: max(0, bounds.height - y - 36))
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "media") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "media")
        let row = rows[indexPath.row]
        cell.backgroundColor = Ui.panel
        cell.textLabel?.text = row.title
        cell.textLabel?.textColor = Ui.text
        cell.textLabel?.font = Ui.font(15)
        cell.detailTextLabel?.text = row.subtitle
        cell.detailTextLabel?.textColor = Ui.muted
        cell.detailTextLabel?.font = Ui.font(11)
        cell.imageView?.image = UIImage(systemName: row.icon)
        cell.imageView?.tintColor = Ui.text
        cell.accessoryType = .disclosureIndicator
        let selected = UIView(); selected.backgroundColor = Ui.active; cell.selectedBackgroundView = selected
        cell.accessibilityLabel = row.title + ". " + row.subtitle
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        rows[indexPath.row].action()
    }
    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let index = table.indexPathForRow(at: recognizer.location(in: table)) else { return }
        rows[index.row].options?()
    }
}

final class MediaServersViewController: PageViewController {
    override var pageTitle: String { "Add server (UPnP)" }
    override var pageSubtitle: String { "Connect your NAS on the same Wi-Fi, then browse it in My Music or My Videos." }
    private let list = MediaListView()
    private var connection: Task<Void, Never>?
    private var busy = false
    override func viewDidLoad() {
        super.viewDidLoad()
        content.addSubview(list)
        content.onLayout = { [weak self] pane in self?.list.frame = pane.bounds }
        list.toolbar([LMButton("＋ Add server") { [weak self] in self?.addServer() }])
        reload()
    }
    deinit { connection?.cancel() }
    private func reload() {
        let servers = MediaServers.all()
        list.hint.text = busy ? "Connecting to your media server…" : servers.isEmpty ? "Add your NAS address or its full UPnP description URL." : "Tap a server to rename, reconnect or remove it."
        list.buttons.first?.isEnabled = !busy
        list.rows = servers.map { server in
            MediaListView.Row(title: server.name, subtitle: server.descriptionURL.host ?? "UPnP media server", icon: "externaldrive.connected.to.line.below", action: { [weak self] in self?.options(server) })
        }
    }
    private func addServer(_ current: UPnPServer? = nil) {
        guard !busy else { return }
        let alert = UIAlertController(title: current == nil ? "Add server (UPnP)" : "Reconnect server", message: "Enter your NAS address, e.g. 192.168.1.20, or its UPnP description URL including the media port. Media Server/DLNA must be enabled on the NAS.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "192.168.1.20 or http://nas:port/description.xml"
            field.text = current?.descriptionURL.absoluteString
            field.keyboardType = .URL
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak alert] _ in
            self?.connect(alert?.textFields?.first?.text ?? "", replacing: current)
        })
        present(alert, animated: true)
    }
    private func connect(_ address: String, replacing old: UPnPServer?) {
        busy = true; reload()
        connection = Task { [weak self] in
            do {
                var server = try await UPnPClient.connect(address)
                try Task.checkCancellation()
                guard let self = self else { return }
                if let old = old {
                    server.name = old.name
                    var servers = MediaServers.all().filter { $0.id != old.id && $0.id != server.id }
                    servers.append(server)
                    try MediaServers.save(servers)
                } else { try MediaServers.add(server) }
                self.busy = false; self.reload()
                Ui.toast("Connected · " + server.name)
            } catch is CancellationError { return }
            catch {
                guard let self = self else { return }
                self.busy = false; self.reload()
                Ui.message(self, title: "Server not added", message: (error as? LibraryError)?.message ?? "Could not save this connection. Please try again.")
            }
        }
    }
    private func options(_ server: UPnPServer) {
        Ui.choose(self, title: server.name, items: ["Rename", "Reconnect / change address", "Remove server"]) { [weak self] selected in
            guard let self = self else { return }
            switch selected {
            case 0:
                Ui.input(self, title: "Server name", text: server.name) { [weak self] name in
                    let name = name.trimmed
                    guard !name.isEmpty else { return }
                    var servers = MediaServers.all()
                    guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
                    servers[index].name = String(name.prefix(80))
                    do { try MediaServers.save(servers); self?.reload() } catch { Ui.toast("Could not save the name") }
                }
            case 1: self.addServer(server)
            default:
                Ui.confirm(self, title: "Remove \(server.name)?", message: "Files on your NAS and completed downloads stay untouched.", ok: "Remove") { [weak self] in
                    do { try MediaServers.save(MediaServers.all().filter { $0.id != server.id }); self?.reload() }
                    catch { Ui.toast("Could not remove the connection") }
                }
            }
        }
    }
}

final class UPnPBrowserView: MediaListView {
    private weak var host: UIViewController?
    private let type: LibraryMediaType
    private let onPlay: (MediaItem) -> Void
    private let onSettings: () -> Void
    private var server: UPnPServer?
    private var path: [(id: String, name: String)] = []
    private var entries: [UPnPEntry] = []
    private var offset = 0
    private var more = false
    private var query = ""
    private var loading = false
    private var ticket = 0
    private var task: Task<Void, Never>?
    init(host: UIViewController, type: LibraryMediaType, onSettings: @escaping () -> Void, onPlay: @escaping (MediaItem) -> Void) {
        self.host = host; self.type = type; self.onPlay = onPlay; self.onSettings = onSettings
        super.init(frame: .zero)
        toolbar([
            LMButton("‹ Back") { [weak self] in self?.back() },
            LMButton("Refresh") { [weak self] in self?.refresh() },
            LMButton("Search") { [weak self] in self?.search() },
            LMButton("＋ Server", action: onSettings)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(serversChanged), name: MediaServers.changed, object: nil)
        showServers()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { task?.cancel(); NotificationCenter.default.removeObserver(self) }
    @objc private func serversChanged() { showServers() }
    private func showServers() {
        task?.cancel(); ticket += 1; loading = false; server = nil; path = []; entries = []; query = ""
        buttons.first?.isEnabled = false
        let servers = MediaServers.all()
        hint.text = servers.isEmpty ? "Add a UPnP server in Settings to browse your \(type == .music ? "music" : "videos")." : "Choose a server · use the same Wi-Fi as your NAS."
        rows = servers.map { server in
            Row(title: server.name, subtitle: "UPnP media library", icon: "externaldrive", action: { [weak self] in
                self?.server = server; self?.path = [("0", server.name)]; self?.refresh()
            })
        }
    }
    private func back() {
        if path.count <= 1 { showServers() }
        else { path.removeLast(); query = ""; refresh() }
    }
    private func refresh() {
        guard server != nil else { showServers(); return }
        task?.cancel(); ticket += 1; loading = false; entries = []; offset = 0; more = false
        fetch()
    }
    private func fetch() {
        guard !loading, let server = server, let folder = path.last else { return }
        loading = true
        buttons.first?.isEnabled = true
        hint.text = "Loading " + folder.name + "…"
        render()
        let current = ticket, start = offset
        task = Task { [weak self] in
            do {
                let page = try await UPnPClient.browse(server, folder: folder.id, start: start)
                try Task.checkCancellation()
                guard let self = self, self.ticket == current else { return }
                let known = Set(self.entries.map { $0.id })
                let new = page.entries.filter { !known.contains($0.id) }
                self.entries.append(contentsOf: new)
                self.offset += page.returned
                self.more = page.hasMore(start: start) && !new.isEmpty
                self.loading = false
                self.hint.text = self.path.map { $0.name }.joined(separator: " › ") + " · Hold a file for downloads"
                self.render()
            } catch is CancellationError { return }
            catch {
                guard let self = self, self.ticket == current else { return }
                self.loading = false
                self.hint.text = (error as? LibraryError)?.message ?? "Could not open this folder. Tap Refresh to retry."
                self.render()
            }
        }
    }
    private func search() {
        guard let host = host, server != nil else { return }
        Ui.input(host, title: "Search this folder", text: query, placeholder: "Leave blank to show everything", ok: "Search") { [weak self] text in
            self?.query = text.trimmed; self?.render()
        }
    }
    private func item(_ entry: UPnPEntry) -> MediaItem? {
        guard let server = server, let resource = entry.resource else { return nil }
        return MediaItem(kind: type == .music ? .AUDIO : .MOVIE, id: "upnp:\(server.id):\(entry.id)", name: entry.title,
            category: server.name, image: entry.artwork, plot: entry.artist, ext: resource.pathExtension, seriesId: "", sourceURL: resource.absoluteString)
    }
    private func render() {
        let filtered = entries.filter { $0.matches(type) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)) }
        rows = filtered.map { entry in
            Row(title: entry.title, subtitle: entry.isFolder ? "Folder" : entry.artist.isEmpty ? "Tap to play · hold for options" : entry.artist,
                icon: entry.isFolder ? "folder" : type == .music ? "music.note" : "film", action: { [weak self] in
                    guard let self = self else { return }
                    if entry.isFolder { self.path.append((entry.id, entry.title)); self.query = ""; self.refresh() }
                    else if let item = self.item(entry) { self.onPlay(item) }
                    else { Ui.toast("This item has no playable HTTP media resource") }
                }, options: entry.isFolder ? nil : { [weak self] in self?.fileOptions(entry) })
        }
        if more && !loading {
            rows.append(Row(title: "Load more…", subtitle: "More items in this folder", icon: "ellipsis", action: { [weak self] in self?.fetch() }))
        } else if rows.isEmpty && !loading {
            rows.append(Row(title: query.isEmpty ? "No \(type == .music ? "music" : "videos") in this folder" : "No matching items", subtitle: "Go back to choose another folder, or refresh to try again.", icon: "folder", action: {}))
        }
    }
    private func fileOptions(_ entry: UPnPEntry) {
        guard let host = host, let item = item(entry) else { return }
        Ui.choose(host, title: entry.title, items: ["Play", "Download to iPhone"]) { [weak self] choice in
            guard let self = self else { return }
            if choice == 0 { self.onPlay(item) }
            else {
                do { try DownloadManager.shared.enqueue(item, provider: nil); Ui.toast("Added to Downloads") }
                catch { Ui.message(host, title: "Download", message: error.localizedDescription) }
            }
        }
    }
}

final class DownloadsView: MediaListView {
    private weak var host: UIViewController?
    private let onPlay: (MediaItem) -> Void
    init(host: UIViewController, onPlay: @escaping (MediaItem) -> Void) {
        self.host = host; self.onPlay = onPlay
        super.init(frame: .zero)
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: DownloadManager.changed, object: nil)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func reload() {
        let records = DownloadManager.shared.records
        hint.text = records.isEmpty ? "Download films, episodes and NAS files from their details or hold menu." : "Saved on this iPhone · tap for play, pause, retry or remove."
        rows = records.map { record in
            Row(title: record.item?.name ?? "Download", subtitle: record.label,
                icon: record.state == "complete" ? "checkmark.circle" : record.state == "paused" ? "pause.circle" : record.state == "failed" ? "exclamationmark.circle" : "arrow.down.circle",
                action: { [weak self] in self?.options(record.id) })
        }
    }
    private func options(_ id: String) {
        guard let host = host, let record = DownloadManager.shared.records.first(where: { $0.id == id }) else { return }
        var choices = [String]()
        switch record.state {
        case "complete": choices.append("Play offline")
        case "downloading": choices.append("Pause download")
        case "paused": choices.append("Resume download")
        default: choices.append("Retry download")
        }
        choices.append(record.state == "complete" ? "Delete download" : "Cancel and remove")
        Ui.choose(host, title: record.item?.name ?? "Download", items: choices) { [weak self] choice in
            guard let self = self else { return }
            if choice == 1 {
                Ui.confirm(host, title: choices[1] + "?", message: "This removes only the copy on this iPhone.", ok: "Remove") {
                    if PlaybackSession.shared.item?.downloadID == id { PlaybackSession.shared.stop() }
                    do { try DownloadManager.shared.remove(id) } catch { Ui.toast("Could not remove the download. Try again.") }
                }
            } else if record.state == "complete", let item = DownloadManager.shared.playable(record) { self.onPlay(item) }
            else if record.state == "downloading" { DownloadManager.shared.pause(id) }
            else { do { try DownloadManager.shared.resume(id) } catch { Ui.message(host, title: "Download", message: error.localizedDescription) } }
        }
    }
}
