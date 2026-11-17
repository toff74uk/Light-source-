import Foundation

enum DownloadValidation {
    static func checkURL(_ url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw LibraryError("This item cannot be downloaded.")
        }
        if ["m3u8", "m3u", "mpd"].contains(url.pathExtension.lowercased()) {
            throw LibraryError("This item uses a streaming playlist. Downloads currently support direct video and music files.")
        }
    }
    static func checkResponse(status: Int, mime: String, prefix: Data, bytes: Int64) throws {
        guard status == 200 else { throw LibraryError("Download failed (HTTP \(status)). Try again from the title or reconnect your provider.") }
        guard bytes > 0 else { throw LibraryError("The server sent an empty file.") }
        let type = mime.lowercased()
        let text = String(data: prefix, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if type.contains("mpegurl") || type.contains("dash+xml") || text.hasPrefix("#extm3u") {
            throw LibraryError("The server sent a streaming playlist. Choose a direct video or music file to download.")
        }
        if type.contains("text/html") || type.contains("application/json") || text.hasPrefix("<!doctype html") || text.hasPrefix("<html") {
            throw LibraryError("The server sent a login or error page instead of media. Check the connection and try again.")
        }
    }
}
