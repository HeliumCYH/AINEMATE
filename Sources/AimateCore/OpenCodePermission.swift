import Foundation

/// OpenCode is the one agent that answers approvals over a network rather than
/// stdin: its desktop app runs a local HTTP server, and the endpoints below are
/// the exact ones its own approval panel calls.
///
/// Everything here is pure so the wire shape can be tested without a server: the
/// server's discovery file, the two URLs, the Basic header and the option →
/// decision mapping are all derived from plain values.
public enum OpenCodePermission {
    public static let allowOption = "允许一次"
    /// OpenCode's own panel offers `always`; without it the pet could only ever
    /// answer one call at a time, which is the case a human is least likely to want.
    public static let alwaysOption = "始终允许"
    public static let denyOption = "拒绝"
    /// Measured at 11 pt semibold: three capsules and two 6 pt gaps are 182 pt in
    /// a 212 pt card interior, so the row keeps the same button size as a two-way ask.
    public static let options = [allowOption, alwaysOption, denyOption]

    /// Written by the server at startup. The password is per launch, so it has to
    /// be read live — caching it would break the first time OpenCode restarts.
    public struct Service: Decodable, Equatable {
        public let url: String
        public let pid: Int
        public let password: String

        public init(url: String, pid: Int = 0, password: String) {
            self.url = url
            self.pid = pid
            self.password = password
        }
    }

    /// The subset of `Permission.Request` a card can show. The wire object also
    /// carries `save`, `metadata` and `source`, none of which change the question.
    public struct Request: Decodable, Equatable {
        public let id: String
        public let sessionID: String
        public let action: String
        public let resources: [String]
        public let message: String?
    }

    public static func stateFile() -> URL {
        if let override = ProcessInfo.processInfo.environment["AIMATE_OPENCODE_SERVICE"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/opencode/service.json")
    }

    public static func service(from stateFile: URL) -> Service? {
        guard let data = FileManager.default.contents(atPath: stateFile.path) else { return nil }
        return try? JSONDecoder().decode(Service.self, from: data)
    }

    /// A stale discovery file outlives a crashed server, and asking a dead port
    /// every tick would just burn the timeout.
    public static func isRunning(_ service: Service) -> Bool {
        service.pid <= 0 || kill(pid_t(service.pid), 0) == 0 || errno == EPERM
    }

    public static func authorization(_ service: Service) -> String {
        "Basic " + Data("opencode:\(service.password)".utf8).base64EncodedString()
    }

    /// `location` is a `deepObject` query parameter, so the bracket is part of the
    /// wire form rather than an array index.
    public static func pendingURL(_ service: Service, directory: String?) -> URL? {
        let base = service.url + "/api/permission/request"
        guard let directory, !directory.isEmpty else { return URL(string: base) }
        // A `urlQueryAllowed` set would leave `&`, `=` and `?` raw and let a path
        // cut the query short; only the characters a path really uses survive.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/-._~"))
        let encoded = directory.addingPercentEncoding(withAllowedCharacters: allowed) ?? directory
        return URL(string: "\(base)?location%5Bdirectory%5D=\(encoded)")
    }

    public static func replyURL(_ service: Service, request: Request) -> URL? {
        let session = request.sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let id = request.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return URL(string: "\(service.url)/api/session/\(session)/permission/\(id)/reply")
    }

    /// Only the labels the card draws are ever sent: an unrecognised one must not
    /// turn into a grant.
    public static func replyBody(forOption option: String) -> Data? {
        let decision: String
        switch option {
        case allowOption: decision = "once"
        case alwaysOption: decision = "always"
        case denyOption: decision = "reject"
        default: return nil
        }
        return try? JSONSerialization.data(withJSONObject: ["decision": decision])
    }

    /// The request id is stable for the lifetime of the question, so a bridge
    /// restart re-adopts the same card instead of leaving a duplicate behind.
    public static func actorID(for request: Request) -> String {
        let head = String(request.sessionID.prefix(8)).lowercased()
            .map { $0.isHexDigit || $0 == "-" ? $0 : "-" }
        return "ask:opencode:\(String(head)):\(request.id)"
    }

    public static func title(for request: Request) -> String {
        for candidate in request.resources + [request.message ?? ""] {
            let flat = flatten(candidate, limit: 72)
            if !flat.isEmpty { return flat }
        }
        return "\(request.action) 请求批准"
    }

    public static func detail(for request: Request) -> String {
        guard let message = request.message else { return request.action }
        let flat = flatten(message, limit: 48)
        guard !flat.isEmpty, flat != title(for: request) else { return request.action }
        return "\(request.action) · \(flat)"
    }

    static func flatten(_ text: String, limit: Int) -> String {
        let flat = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return "" }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// The server answers a permission list only for the location you name, and each
/// location is a directory a session was started in. Reading them out of the
/// session table is how one bridge covers every open project.
public enum OpenCodeLocations {
    public static func active(
        databasePath: String, window: TimeInterval = 3600, now: Date = Date()
    ) -> [String] {
        let reader = SQLiteReader()
        guard reader.open(databasePath) else { return [] }
        let cutoff = Int((now.timeIntervalSince1970 - window) * 1000)
        let rows = reader.query(
            """
            select distinct directory from session
            where directory is not null and time_updated > ?
            """,
            params: [cutoff]) ?? []
        return rows.compactMap { $0["directory"] ?? nil }.filter { !$0.isEmpty }
    }
}
