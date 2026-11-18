import Foundation

/// Turns what the user typed ("10.103.210.50", "dmxtra.local:8080",
/// "http://127.0.0.1:8080/") into the controller's base URL.
enum ControllerAddress {
    static func baseURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }

        guard var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty, !host.contains(" "),
              comps.path.isEmpty, comps.query == nil, comps.fragment == nil
        else { return nil }
        if let port = comps.port, !(1...65535).contains(port) { return nil }
        comps.scheme = scheme
        return comps.url
    }
}
