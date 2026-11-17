import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
func rejects(_ message: String, _ action: () throws -> Void) {
    do { try action(); fatalError(message) } catch { }
}

let base = URL(string: "http://192.168.1.20:50001/description.xml")!
let device = """
<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><URLBase>http://192.168.1.20:50001/</URLBase><device><friendlyName>Music &amp; Films</friendlyName><UDN>uuid:test</UDN><serviceList><service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><controlURL>/wrong</controlURL></service><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>/ctl/ContentDir</controlURL></service></serviceList></device></root>
"""
let server = try UPnPClient.parseServer(Data(device.utf8), descriptionURL: base)
expect(server.name == "Music & Films", "Friendly name/entity decoding")
expect(server.id == "uuid:test", "Stable device identity")
expect(server.controlURL.absoluteString == "http://192.168.1.20:50001/ctl/ContentDir", "ContentDirectory service resolution")
let relative = device.replacingOccurrences(of: "<URLBase>http://192.168.1.20:50001/</URLBase>", with: "").replacingOccurrences(of: "/ctl/ContentDir", with: "ctl/ContentDir")
let relativeServer = try UPnPClient.parseServer(Data(relative.utf8), descriptionURL: base)
expect(relativeServer.controlURL == server.controlURL, "Relative service URL")
let didl = """
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><container id="A&amp;B"><dc:title>Albums</dc:title><upnp:class>object.container.album.musicAlbum</upnp:class></container><item id="song"><dc:title>Track &amp; One</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><upnp:artist>Artist</upnp:artist><res protocolInfo="rtsp-rtp-udp:*:audio/mpeg:*">rtsp://nas/song</res><res protocolInfo="http-get:*:audio/flac:*">/music/track.flac?x=1&amp;y=2</res></item><item id="film"><dc:title>Film</dc:title><upnp:class>object.item.videoItem.movie</upnp:class><res protocolInfo="http-get:*:video/x-matroska:*">http://192.168.1.20/film.mkv</res></item><item id="photo"><dc:title>Photo</dc:title><upnp:class>object.item.imageItem.photo</upnp:class><res protocolInfo="http-get:*:image/jpeg:*">/photo.jpg</res></item></DIDL-Lite>
"""
func soap(_ result: String, returned: Int = 4, total: Int = 10) -> Data {
    Data("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:BrowseResponse xmlns:u=\"urn:schemas-upnp-org:service:ContentDirectory:1\"><Result>\(result)</Result><NumberReturned>\(returned)</NumberReturned><TotalMatches>\(total)</TotalMatches></u:BrowseResponse></s:Body></s:Envelope>".utf8)
}
let page = try UPnPClient.parsePage(soap(UPnPClient.escape(didl)), base: base)
expect(page.entries.count == 4, "DIDL entries")
expect(page.entries[0].id == "A&B", "Object IDs preserve escaped characters")
expect(page.entries.filter { $0.matches(.music) }.count == 2, "Music excludes video/photo and retains folders")
expect(page.entries.filter { $0.matches(.videos) }.count == 2, "Video excludes audio/photo and retains folders")
expect(page.entries[1].resource?.absoluteString == "http://192.168.1.20:50001/music/track.flac?x=1&y=2", "Playable resource preference and URL decoding")
expect(page.hasMore(start: 0) && !page.hasMore(start: 6), "Pagination uses raw returned count")
let cdata = try UPnPClient.parsePage(soap("<![CDATA[\(didl)]]>", total: 0), base: base)
expect(cdata.entries.count == 4 && cdata.hasMore(start: 0), "CDATA and unknown total")
let empty = try UPnPClient.parsePage(soap("", returned: 0, total: 0), base: base)
expect(!empty.hasMore(start: 200), "Unknown-total pagination terminates")
rejects("Reject malformed XML") { _ = try MediaXML.parse(Data("<root>".utf8)) }
rejects("Reject external entities") { _ = try MediaXML.parse(Data("<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><root>&x;</root>".utf8)) }
rejects("Reject non-media device") { _ = try UPnPClient.parseServer(Data("<root><device/></root>".utf8), descriptionURL: base) }
expect(UPnPClient.httpURL("file:///etc/passwd") == nil, "Reject local file resources")
expect(UPnPClient.httpURL("http://user:pass@nas/media") == nil, "Reject embedded credentials")
let candidates = try UPnPClient.candidates("192.168.1.20")
expect(candidates.first == base, "Synology host shortcut")
let explicit = try UPnPClient.candidates(base.absoluteString)
expect(explicit == [base], "Explicit description URL stays exact")
try DownloadValidation.checkURL(URL(string: "http://nas/film.mkv")!)
rejects("Reject live playlist downloads") { try DownloadValidation.checkURL(URL(string: "https://nas/live.m3u8")!) }
try DownloadValidation.checkResponse(status: 200, mime: "video/mp4", prefix: Data([0, 0, 0, 24]), bytes: 2048)
rejects("Reject server error files") { try DownloadValidation.checkResponse(status: 403, mime: "video/mp4", prefix: Data(), bytes: 50) }
rejects("Reject masquerading playlists") { try DownloadValidation.checkResponse(status: 200, mime: "application/octet-stream", prefix: Data("#EXTM3U\n".utf8), bytes: 100) }
rejects("Reject login pages") { try DownloadValidation.checkResponse(status: 200, mime: "text/html", prefix: Data("<html>Login".utf8), bytes: 100) }
rejects("Reject empty files") { try DownloadValidation.checkResponse(status: 200, mime: "video/mp4", prefix: Data(), bytes: 0) }
print("Media library parser, paging and download validation checks passed.")
