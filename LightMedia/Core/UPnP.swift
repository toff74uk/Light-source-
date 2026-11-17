import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct LibraryError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct UPnPServer: Codable, Equatable {
    let id: String
    var name: String
    let descriptionURL: URL
    let controlURL: URL
    let serviceType: String
}

enum LibraryMediaType: String { case music, videos }

struct UPnPEntry {
    let id: String
    let title: String
    let isFolder: Bool
    let mediaClass: String
    let resource: URL?
    let mimeType: String
    let artwork: String
    let artist: String

    func matches(_ type: LibraryMediaType) -> Bool {
        if isFolder { return true }
        return type == .music ? mediaClass.contains("audioItem") || mimeType.hasPrefix("audio/")
            : mediaClass.contains("videoItem") || mimeType.hasPrefix("video/")
    }
}

struct UPnPPage {
    let entries: [UPnPEntry]
    let returned: Int
    let total: Int

    func hasMore(start: Int) -> Bool {
        // Some servers report an unknown total as zero. Fetch until an empty page.
        return returned > 0 && (total == 0 || start + returned < total)
    }
}

/// Small bounded XML tree. No external entities, DTDs or network resolution.
final class MediaXML: NSObject, XMLParserDelegate {
    final class Node {
        let name: String
        let attributes: [String: String]
        var text = ""
        var children: [Node] = []
        init(_ name: String, _ attributes: [String: String] = [:]) {
            self.name = name.split(separator: ":").last.map(String.init) ?? name
            self.attributes = attributes
        }
        func child(_ name: String) -> Node? { children.first { $0.name == name } }
        func value(_ name: String) -> String { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func descendants(_ name: String) -> [Node] {
            children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
        }
    }
    private let root = Node("root")
    private var stack: [Node] = []
    private var count = 0
    static func parse(_ data: Data) throws -> Node {
        guard data.count <= 8 * 1024 * 1024 else { throw LibraryError("The media folder is too large to read.") }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw LibraryError("The server returned unsupported XML.")
        }
        let delegate = MediaXML()
        delegate.stack = [delegate.root]
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw LibraryError("The server did not return a valid UPnP media response.") }
        return delegate.root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 64, count < 100_000 else { parser.abortParsing(); return }
        let node = Node(elementName, attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
}

enum UPnPClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    static func httpURL(_ text: String, relativeTo base: URL? = nil) -> URL? {
        guard let url = URL(string: text, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func candidates(_ input: String) throws -> [URL] {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = httpURL(value.contains("://") ? value : "http://" + value) else {
            throw LibraryError("Enter your NAS address, including its media port, or a full UPnP description URL.")
        }
        if url.path != "" && url.path != "/" { return [url] }
        var urls = [url.appendingPathComponent("description.xml"), url.appendingPathComponent("rootDesc.xml"), url]
        if url.port == nil, url.scheme == "http", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // Common Synology Media Server endpoint, tried only on the host the user enters.
            parts.port = 50001
            parts.path = "/description.xml"
            if let synology = parts.url { urls.insert(synology, at: 0) }
        }
        return urls
    }

    static func connect(_ input: String) async throws -> UPnPServer {
        for url in try candidates(input) {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                return try parseServer(data, descriptionURL: response.url ?? url)
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw LibraryError("Could not connect to a UPnP media server. Check the address and port, enable Media Server/DLNA on your NAS, and allow Light Media in iPhone Settings → Privacy & Security → Local Network. Use the same Wi-Fi as your NAS.")
    }

    static func parseServer(_ data: Data, descriptionURL: URL) throws -> UPnPServer {
        let root = try MediaXML.parse(data)
        let baseText = root.descendants("URLBase").first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = baseText.isEmpty ? descriptionURL : httpURL(baseText) ?? descriptionURL
        guard let service = root.descendants("service").first(where: {
            $0.value("serviceType").hasPrefix("urn:schemas-upnp-org:service:ContentDirectory:")
        }), let control = httpURL(service.value("controlURL"), relativeTo: base), !service.value("controlURL").isEmpty else {
            throw LibraryError("This address is not a UPnP media server. Use its device description URL.")
        }
        let device = root.descendants("device").first
        let name = device?.value("friendlyName") ?? ""
        let udn = device?.value("UDN") ?? ""
        return UPnPServer(id: udn.isEmpty ? descriptionURL.absoluteString : udn,
                          name: name.isEmpty ? descriptionURL.host ?? "Media server" : name,
                          descriptionURL: descriptionURL, controlURL: control, serviceType: service.value("serviceType"))
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func browse(_ server: UPnPServer, folder: String, start: Int = 0) async throws -> UPnPPage {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:Browse xmlns:u="\(escape(server.serviceType))"><ObjectID>\(escape(folder))</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>\(max(0, start))</StartingIndex><RequestedCount>200</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>
        """
        var request = URLRequest(url: server.controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(server.serviceType)#Browse\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(xml.utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw LibraryError("The server could not open this folder. Try refreshing or reconnecting it in Settings.")
            }
            return try parsePage(data, base: server.descriptionURL)
        } catch let error as LibraryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw LibraryError("The media server is unavailable. Check your Wi-Fi connection, then tap Refresh.") }
    }

    static func parsePage(_ data: Data, base: URL) throws -> UPnPPage {
        let root = try MediaXML.parse(data)
        guard let response = root.descendants("BrowseResponse").first,
              let result = response.child("Result") else { throw LibraryError("The server returned an invalid folder listing.") }
        let didl = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = didl.isEmpty ? result : try MediaXML.parse(Data(didl.utf8))
        let nodes = parsed.descendants("DIDL-Lite").first?.children ?? []
        var entries: [UPnPEntry] = []
        for node in nodes where node.name == "container" || node.name == "item" {
            guard let id = node.attributes["id"] else { continue }
            let resources = node.children.filter { $0.name == "res" }
            // Prefer an original HTTP resource over thumbnail/alternate protocols.
            let resource = resources.first {
                let protocolInfo = $0.attributes["protocolInfo"] ?? ""
                return protocolInfo.hasPrefix("http-get:") && !protocolInfo.contains(":image/") && httpURL($0.text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base) != nil
            }
            let info = resource?.attributes["protocolInfo"]?.split(separator: ":", omittingEmptySubsequences: false) ?? []
            let title = node.value("title")
            let art = httpURL(node.value("albumArtURI"), relativeTo: base)
            entries.append(UPnPEntry(id: id, title: title.isEmpty ? "Untitled" : title,
                isFolder: node.name == "container", mediaClass: node.value("class"),
                resource: resource.flatMap { httpURL($0.text.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base) },
                mimeType: info.count > 2 ? String(info[2]) : "", artwork: node.value("albumArtURI").isEmpty ? "" : art?.absoluteString ?? "",
                artist: node.value("artist")))
        }
        return UPnPPage(entries: entries, returned: max(0, Int(response.value("NumberReturned")) ?? nodes.count),
                        total: max(0, Int(response.value("TotalMatches")) ?? 0))
    }
}
