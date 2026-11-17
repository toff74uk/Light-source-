import Foundation

struct DownloadRecord: Codable {
    let id: String
    let scope: String
    let mediaJSON: String
    let filename: String
    var state: String
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String = ""
    var item: MediaItem? { MediaItem.from(text: mediaJSON) }
    var label: String {
        let size = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        switch state {
        case "complete": return "Downloaded · " + size
        case "paused": return "Paused · " + size
        case "failed": return error
        default:
            return expected > 0 ? "\(min(100, received * 100 / max(1, expected)))% · " + size : "Downloading · " + size
        }
    }
}

/// All mutations and URLSession delegate callbacks run on the main queue.
/// Transfer URLs stay in Keychain; neither provider credentials nor URLs enter the manifest.
final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    static let identifier = "com.rg.lightmedia.downloads.v1"
    static let changed = Notification.Name("LightMediaDownloadsChanged")
    var backgroundCompletion: (() -> Void)?
    private(set) var records: [DownloadRecord] = []
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var lastNotice = Date.distantPast
    private var reconciled = false
    private var persistenceError = false
    private let directory = Prefs.directory.appendingPathComponent("Downloads", isDirectory: true)
    private var manifest: URL { directory.appendingPathComponent("index.json") }
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            if FileManager.default.fileExists(atPath: manifest.path) {
                records = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: manifest))
            }
        } catch { persistenceError = true }
    }

    func start() {
        session.getAllTasks { [weak self] all in
            DispatchQueue.main.async {
                guard let self = self else { return }
                for task in all {
                    guard let download = task as? URLSessionDownloadTask, let id = task.taskDescription,
                          let index = self.records.firstIndex(where: { $0.id == id }),
                          self.records[index].state != "complete" else { task.cancel(); continue }
                    self.tasks[id] = download
                    if self.records[index].state == "paused" { if download.state == .running { download.suspend() } }
                    else { download.resume() }
                }
                for index in self.records.indices {
                    let record = self.records[index]
                    if record.state == "downloading" && self.tasks[record.id] == nil {
                        self.records[index].state = "failed"
                        self.records[index].error = "Download interrupted. Tap to retry."
                    }
                    if record.state == "complete" && !FileManager.default.fileExists(atPath: self.file(record).path) {
                        self.records[index].state = "failed"
                        self.records[index].error = "The downloaded file is missing. Tap to retry."
                    }
                }
                self.reconciled = true
                self.saveAndNotify()
            }
        }
    }

    private func file(_ record: DownloadRecord) -> URL { directory.appendingPathComponent(record.filename) }
    private func sourceKey(_ id: String) -> String { "download-source/" + id }
    private func resumeFile(_ id: String) -> URL { directory.appendingPathComponent(id + ".resume") }
    private func scope(_ item: MediaItem) -> String { item.sourceURL.isEmpty ? LocalStore.shared.scope : "upnp" }

    func existing(_ item: MediaItem) -> DownloadRecord? {
        records.first { $0.item?.key == item.key && $0.scope == scope(item) }
    }
    func localURL(_ item: MediaItem) -> URL? {
        let record = item.downloadID.isEmpty ? existing(item) : records.first { $0.id == item.downloadID }
        guard let record = record, record.state == "complete", FileManager.default.fileExists(atPath: file(record).path) else { return nil }
        return file(record)
    }
    func playable(_ record: DownloadRecord) -> MediaItem? {
        guard record.state == "complete", var item = record.item else { return nil }
        item.downloadID = record.id
        return item
    }

    func enqueue(_ item: MediaItem, provider: Provider?) throws {
        guard reconciled else { throw LibraryError("Restoring downloads. Please try again in a moment.") }
        guard !persistenceError else { throw LibraryError("Downloads could not be saved on this iPhone. Check free storage and reopen the app.") }
        guard item.kind != .LIVE && item.kind != .SERIES else { throw LibraryError("Choose a film, episode or music track to download.") }
        if let old = existing(item) {
            if old.state == "failed" || old.state == "paused" { try resume(old.id) }
            return
        }
        let address = item.sourceURL.isEmpty ? provider?.streamUrl(item, liveFormat: "ts") ?? "" : item.sourceURL
        guard let url = URL(string: address) else { throw LibraryError("Connect a provider or media server before downloading.") }
        try DownloadValidation.checkURL(url)
        let id = UUID().uuidString
        guard Keychain.set(Data(address.utf8), account: sourceKey(id)) else { throw LibraryError("Could not save this download securely.") }
        var ext = url.pathExtension.lowercased()
        if ext.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) == nil { ext = "media" }
        let record = DownloadRecord(id: id, scope: scope(item), mediaJSON: item.jsonString(), filename: id + "." + ext, state: "downloading")
        records.insert(record, at: 0)
        do { try persist() } catch {
            records.removeAll { $0.id == id }
            Keychain.remove(account: sourceKey(id))
            throw LibraryError("Could not save the download. Check free storage.")
        }
        createTask(id, url: url)
        notify()
    }

    private func createTask(_ id: String, url: URL) {
        var request = URLRequest(url: url)
        request.setValue("RGTV/2.3", forHTTPHeaderField: "User-Agent")
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile(id)) { task = session.downloadTask(withResumeData: data) }
        else { task = session.downloadTask(with: request) }
        try? FileManager.default.removeItem(at: resumeFile(id))
        task.taskDescription = id
        tasks[id] = task
        task.resume()
    }

    func pause(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), let task = tasks[id], records[index].state == "downloading" else { return }
        // Keeping the same suspended task avoids cancellation/resume-data races.
        task.suspend()
        records[index].state = "paused"
        saveAndNotify()
    }

    func resume(_ id: String) throws {
        guard reconciled, let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].state != "complete" else { return }
        if let task = tasks[id] {
            records[index].state = "downloading"
            records[index].error = ""
            task.resume()
        } else {
            guard let data = Keychain.get(account: sourceKey(id)), let address = String(data: data, encoding: .utf8), let url = URL(string: address) else {
                throw LibraryError("The saved download link is unavailable. Remove this entry and download it again from the title.")
            }
            records[index].state = "downloading"
            records[index].error = ""
            records[index].received = 0
            createTask(id, url: url)
        }
        saveAndNotify()
    }

    func remove(_ id: String) throws {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if FileManager.default.fileExists(atPath: file(record).path) { try FileManager.default.removeItem(at: file(record)) }
        records.removeAll { $0.id == id }
        tasks.removeValue(forKey: id)?.cancel()
        try? FileManager.default.removeItem(at: resumeFile(id))
        Keychain.remove(account: sourceKey(id))
        try persist()
        notify()
    }

    private func persist() throws {
        guard !persistenceError else { throw LibraryError("The downloads index could not be opened.") }
        let data = try JSONEncoder().encode(records)
        try data.write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func saveAndNotify() {
        do { try persist() } catch { /* Completed media remains available in this session; UI reports save failure. */
            Ui.toast("Could not save download progress. Check free storage.")
        }
        notify()
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].received = totalBytesWritten
        records[index].expected = max(0, totalBytesExpectedToWrite)
        if Date().timeIntervalSince(lastNotice) > 0.5 { lastNotice = Date(); notify() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let index = records.firstIndex(where: { $0.id == id }) else { return }
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            let bytes = Int64(values.fileSize ?? 0)
            let handle = try FileHandle(forReadingFrom: location)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 512) ?? Data()
            try DownloadValidation.checkResponse(status: (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0,
                mime: downloadTask.response?.mimeType ?? "", prefix: prefix, bytes: bytes)
            let destination = file(records[index])
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            records[index].state = "complete"
            records[index].received = bytes
            records[index].expected = bytes
            records[index].error = ""
        } catch {
            records[index].state = "failed"
            records[index].error = (error as? LibraryError)?.message ?? "Could not save the file. Check free storage and retry."
        }
        saveAndNotify()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        tasks.removeValue(forKey: id)
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].state != "complete" else { return }
        if let error = error as NSError? {
            if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                try? data.write(to: resumeFile(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            records[index].state = "failed"
            records[index].error = error.code == NSURLErrorCannotWriteToFile ? "Not enough storage to save this download. Free space and retry." : "Download interrupted. Check your connection and tap Retry."
            saveAndNotify()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }
}
