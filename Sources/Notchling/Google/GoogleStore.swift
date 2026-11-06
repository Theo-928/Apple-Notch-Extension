import AppKit
import Foundation

/// Google Calendar, Gmail and Tasks, talked to directly over their REST APIs.
/// Using Google's servers (instead of the macOS Calendar/Reminders databases)
/// means no Calendars/Reminders privacy permission is needed on the Mac.
@MainActor
final class GoogleStore: ObservableObject {
    enum Status: Equatable {
        case notConfigured
        case signedOut
        case signingIn
        case signedIn(email: String)
    }

    struct CalendarEvent: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let meetingURL: URL?
        let htmlLink: URL?
        let location: String?

        var isOngoing: Bool { start <= Date() && end > Date() }
    }

    struct MailMessage: Identifiable, Equatable {
        let id: String
        let threadID: String
        let from: String
        let subject: String
        let snippet: String
    }

    struct TaskItem: Identifiable, Equatable {
        let id: String
        let title: String
        let due: Date?
    }

    @Published private(set) var status: Status = .notConfigured
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var unreadCount: Int?
    @Published private(set) var messages: [MailMessage] = []
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false

    let auth: GoogleAuth
    private let settings: AppSettings
    private var pollTimer: Timer?

    init(settings: AppSettings) {
        self.settings = settings
        self.auth = GoogleAuth(settings: settings)
        updateStatus()
        if case .signedIn = status { Task { await refresh() } }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .signedIn = self.status else { return }
                Task { await self.refresh() }
            }
        }
    }

    var email: String? {
        if case .signedIn(let email) = status { return email }
        return nil
    }

    /// Next timed event that's ongoing or starts within the next 10 minutes.
    var imminentEvent: CalendarEvent? {
        let now = Date()
        return events.first { !$0.isAllDay && $0.end > now && $0.start.timeIntervalSince(now) < 600 }
    }

    var upcomingEvents: [CalendarEvent] {
        let now = Date()
        return events.filter { $0.end > now }
    }

    func updateStatus() {
        if status == .signingIn { return }
        if settings.googleClientID.trimmingCharacters(in: .whitespaces).isEmpty {
            status = .notConfigured
        } else if auth.hasRefreshToken {
            status = .signedIn(email: UserDefaults.standard.string(forKey: "googleEmail") ?? "Google account")
        } else {
            status = .signedOut
        }
    }

    // MARK: Account

    func signIn() async {
        lastError = nil
        status = .signingIn
        do {
            try await auth.signIn()
            let email = (try? await fetchEmail()) ?? "Google account"
            UserDefaults.standard.set(email, forKey: "googleEmail")
            status = .signedIn(email: email)
            await refresh()
        } catch {
            lastError = error.localizedDescription
            status = .signedOut
            updateStatus()
        }
    }

    func cancelSignIn() { auth.cancelSignIn() }

    func signOut() async {
        await auth.signOut()
        UserDefaults.standard.removeObject(forKey: "googleEmail")
        events = []; messages = []; tasks = []; unreadCount = nil
        updateStatus()
    }

    // MARK: Refresh

    func refreshIfStale() {
        guard case .signedIn = status, !isRefreshing else { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 60 { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard case .signedIn = status, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastError = nil
        async let e = loadEvents()
        async let m = settings.gmailEnabled ? loadMail() : nil
        async let t = settings.tasksEnabled ? loadTasks() : nil
        do {
            events = try await e
            if let mail = try await m { unreadCount = mail.0; messages = mail.1 } else { unreadCount = nil; messages = [] }
            tasks = try await t ?? []
            lastRefresh = Date()
        } catch GoogleAuth.AuthError.notSignedIn {
            lastError = "Your Google session expired. Sign in again."
            await signOut()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Calendar

    private func loadEvents() async throws -> [CalendarEvent] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 2, to: startOfDay)!
        let iso = ISO8601DateFormatter()
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: iso.string(from: startOfDay)),
            .init(name: "timeMax", value: iso.string(from: end)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "30"),
        ]
        let json = try await getJSON(comps.url!)
        let items = json["items"] as? [[String: Any]] ?? []
        return items.compactMap(Self.parseEvent)
    }

    private static func parseEvent(_ item: [String: Any]) -> CalendarEvent? {
        guard (item["status"] as? String) != "cancelled",
              let id = item["id"] as? String,
              let startObj = item["start"] as? [String: Any],
              let endObj = item["end"] as? [String: Any] else { return nil }
        // Skip events the user declined.
        if let attendees = item["attendees"] as? [[String: Any]],
           attendees.contains(where: { ($0["self"] as? Bool) == true && ($0["responseStatus"] as? String) == "declined" }) {
            return nil
        }
        let allDay = startObj["date"] != nil
        guard let start = parseGoogleDate(startObj), let end = parseGoogleDate(endObj) else { return nil }

        var meeting: URL?
        if let conf = item["conferenceData"] as? [String: Any],
           let entries = conf["entryPoints"] as? [[String: Any]],
           let video = entries.first(where: { ($0["entryPointType"] as? String) == "video" }),
           let uri = video["uri"] as? String {
            meeting = URL(string: uri)
        } else if let hangout = item["hangoutLink"] as? String {
            meeting = URL(string: hangout)
        } else if let text = [item["location"] as? String, item["description"] as? String].compactMap({ $0 }).first(where: { $0.contains("zoom.us/") || $0.contains("teams.microsoft.com/") }) {
            meeting = firstURL(in: text)
        }
        return CalendarEvent(
            id: id,
            title: (item["summary"] as? String) ?? "(No title)",
            start: start, end: end, isAllDay: allDay,
            meetingURL: meeting,
            htmlLink: (item["htmlLink"] as? String).flatMap(URL.init(string:)),
            location: item["location"] as? String
        )
    }

    private static func parseGoogleDate(_ obj: [String: Any]) -> Date? {
        if let dt = obj["dateTime"] as? String {
            let f = ISO8601DateFormatter()
            if let d = f.date(from: dt) { return d }
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: dt)
        }
        if let d = obj["date"] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            return f.date(from: d)
        }
        return nil
    }

    private static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    // MARK: Gmail

    private func loadMail() async throws -> (Int, [MailMessage]) {
        let base = "https://gmail.googleapis.com/gmail/v1/users/me"
        let label = try await getJSON(URL(string: "\(base)/labels/INBOX")!)
        let unread = (label["messagesUnread"] as? NSNumber)?.intValue ?? 0

        var comps = URLComponents(string: "\(base)/messages")!
        comps.queryItems = [.init(name: "q", value: "is:unread in:inbox"), .init(name: "maxResults", value: "6")]
        let list = try await getJSON(comps.url!)
        let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }

        let fetched = try await withThrowingTaskGroup(of: (Int, MailMessage?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask { @MainActor in
                    var c = URLComponents(string: "\(base)/messages/\(id)")!
                    c.queryItems = [
                        .init(name: "format", value: "metadata"),
                        .init(name: "metadataHeaders", value: "From"),
                        .init(name: "metadataHeaders", value: "Subject"),
                    ]
                    let msg = try await self.getJSON(c.url!)
                    let headers = (msg["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
                    func header(_ name: String) -> String {
                        headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
                    }
                    return (index, MailMessage(
                        id: id,
                        threadID: msg["threadId"] as? String ?? id,
                        from: Self.displayName(header("From")),
                        subject: header("Subject").isEmpty ? "(No subject)" : header("Subject"),
                        snippet: (msg["snippet"] as? String ?? "").decodingHTMLEntities
                    ))
                }
            }
            var results: [(Int, MailMessage?)] = []
            for try await r in group { results.append(r) }
            return results.sorted { $0.0 < $1.0 }.compactMap(\.1)
        }
        return (unread, fetched)
    }

    private static func displayName(_ from: String) -> String {
        // "Jane Doe <jane@x.com>" → "Jane Doe"
        if let lt = from.firstIndex(of: "<") {
            let name = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
        }
        return from.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    func openMessage(_ message: MailMessage) {
        openGmail(fragment: "inbox/\(message.threadID)")
    }

    func openInbox() { openGmail(fragment: "inbox") }

    private func openGmail(fragment: String) {
        var comps = URLComponents(string: "https://mail.google.com/mail/")!
        if let email { comps.queryItems = [.init(name: "authuser", value: email)] }
        comps.fragment = fragment
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Tasks

    private func loadTasks() async throws -> [TaskItem] {
        var comps = URLComponents(string: "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks")!
        comps.queryItems = [
            .init(name: "showCompleted", value: "false"),
            .init(name: "maxResults", value: "30"),
        ]
        let json = try await getJSON(comps.url!)
        let items = json["items"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items
            .sorted { ($0["position"] as? String ?? "") < ($1["position"] as? String ?? "") }
            .compactMap { item in
                guard let id = item["id"] as? String,
                      let title = item["title"] as? String, !title.isEmpty else { return nil }
                return TaskItem(id: id, title: title, due: (item["due"] as? String).flatMap(iso.date(from:)))
            }
    }

    func complete(_ task: TaskItem) async {
        tasks.removeAll { $0.id == task.id }
        do {
            let url = URL(string: "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks/\(task.id)")!
            _ = try await send(url, method: "PATCH", body: ["status": "completed"])
        } catch {
            lastError = error.localizedDescription
            await refresh()
        }
    }

    func addTask(title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let url = URL(string: "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks")!
            let json = try await send(url, method: "POST", body: ["title": trimmed])
            if let id = json["id"] as? String { tasks.insert(TaskItem(id: id, title: trimmed, due: nil), at: 0) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: HTTP

    private func fetchEmail() async throws -> String? {
        let json = try await getJSON(URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        return json["email"] as? String
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        try await send(url, method: "GET", body: nil)
    }

    private func send(_ url: URL, method: String, body: [String: Any]?, retry: Bool = true) async throws -> [String: Any] {
        let token = try await auth.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401, retry {
            _ = try await auth.accessToken(forceRefresh: true)
            return try await send(url, method: method, body: body, retry: false)
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(code) else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            throw GoogleAuth.AuthError.server(message)
        }
        return json
    }
}

private extension String {
    var decodingHTMLEntities: String {
        var s = self
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s
    }
}
