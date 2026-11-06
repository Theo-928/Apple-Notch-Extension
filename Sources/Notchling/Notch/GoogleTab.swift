import SwiftUI

struct GoogleTab: View {
    @EnvironmentObject var google: GoogleStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var actions: AppActions

    var body: some View {
        switch google.status {
        case .notConfigured:
            VStack(spacing: 8) {
                EmptyStateView(systemImage: "calendar.badge.plus",
                               title: "Connect your Google account",
                               detail: "Calendar, Gmail and Tasks — read straight from Google,\nso no macOS Calendar or Reminders permission is needed.")
                PillButton(title: "Set up in Settings", systemImage: "gearshape") { actions.openSettings() }
            }
        case .signedOut:
            VStack(spacing: 8) {
                EmptyStateView(systemImage: "person.crop.circle.badge.plus",
                               title: "Signed out",
                               detail: google.lastError ?? "Sign in with Google in your browser.")
                PillButton(title: "Sign in with Google", systemImage: "arrow.up.forward.app") {
                    Task { await google.signIn() }
                }
            }
        case .signingIn:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…").font(.system(size: 12))
                PillButton(title: "Cancel", systemImage: "xmark") { google.cancelSignIn() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedIn:
            signedIn
        }
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = google.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.red.opacity(0.85)).lineLimit(1)
            }
            HStack(alignment: .top, spacing: 12) {
                CalendarColumn()
                if settings.gmailEnabled {
                    divider
                    MailColumn()
                }
                if settings.tasksEnabled {
                    divider
                    TasksColumn()
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { Task { await google.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(google.isRefreshing ? 360 : 0))
                    .animation(google.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: google.isRefreshing)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Refresh")
            .offset(y: -2)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
    }
}

private struct CalendarColumn: View {
    @EnvironmentObject var google: GoogleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Today & tomorrow", systemImage: "calendar")
            if google.upcomingEvents.isEmpty {
                Text("No more events").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(google.upcomingEvents) { event in EventRow(event: event) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MailColumn: View {
    @EnvironmentObject var google: GoogleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { google.openInbox() } label: {
                SectionLabel(text: "Inbox · \(google.unreadCount ?? 0) unread", systemImage: "envelope")
            }
            .buttonStyle(.plain)
            if google.messages.isEmpty {
                Text("Inbox zero ✨").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(google.messages) { msg in
                        Button { google.openMessage(msg) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(msg.from).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Text(msg.subject).font(.system(size: 11)).lineLimit(1)
                                    .foregroundStyle(.white.opacity(0.65))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(msg.snippet)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TasksColumn: View {
    @EnvironmentObject var google: GoogleStore
    @StateObject private var newTask = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Tasks", systemImage: "checklist")
            TextField("Add a task…", text: $newTask.value)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .onSubmit {
                    let title = newTask.value
                    newTask.value = ""
                    Task { await google.addTask(title: title) }
                }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(google.tasks) { task in
                        HStack(alignment: .top, spacing: 6) {
                            Button { Task { await google.complete(task) } } label: {
                                Image(systemName: "circle").font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Mark complete")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.title).font(.system(size: 11)).lineLimit(2)
                                if let due = task.due {
                                    Text(due.formatted(.dateTime.month(.abbreviated).day()))
                                        .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
