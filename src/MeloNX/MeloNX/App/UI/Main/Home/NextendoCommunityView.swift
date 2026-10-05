import SwiftUI

struct NextendoCommunityView: View {
    @ObservedObject private var client = NextendoClient.shared
    @State private var isRefreshing = false
    @State private var errorMessage: String?

    var body: some View {
        iOSNav {
            List {
                Section("Account") {
                    if let session = client.session {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(session.user.displayName ?? session.user.username)
                                .font(.headline)
                            Text("@\(session.user.username)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let friendCode = session.user.friendCode, !friendCode.isEmpty {
                                Text(friendCode)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button("Disconnect Nextendo", role: .destructive) {
                            client.logout()
                        }
                    } else if NextendoClient.hasConfiguredOAuthClient {
                        Button {
                            Task { await signIn() }
                        } label: {
                            Label("Connect Nextendo", systemImage: "person.crop.circle.badge.plus")
                        }
                        .disabled(client.isAuthenticating)

                        if client.isAuthenticating {
                            ProgressView("Waiting for Nextendo…")
                        }
                    } else {
                        Label("Nextendo app registration is required", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Link(
                            "Register this iOS client",
                            destination: URL(string: "https://nextendo.network/developers")!
                        )
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section("Friends · \(client.friends.count)") {
                    if client.session == nil {
                        Text("Connect a Nextendo account to see friends.")
                            .foregroundStyle(.secondary)
                    } else if client.friends.isEmpty {
                        Text("No friends yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(client.friends) { friend in
                            friendRow(friend)
                        }
                    }
                }
            }
            .navigationTitle("Nextendo Network")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(client.session == nil || isRefreshing)
                    .accessibilityLabel("Refresh friends")
                }
            }
            .refreshable {
                await refresh()
            }
            .task {
                client.startOnlineCountsPolling()
            }
        }
    }

    private func friendRow(_ friend: NextendoFriend) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(friend.online ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(friend.name.flatMap { $0.isEmpty ? nil : $0 } ?? friend.username)
                    .font(.body.weight(.medium))
                Text(presenceText(for: friend))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func presenceText(for friend: NextendoFriend) -> String {
        guard friend.online else { return "Offline" }
        guard let appID = friend.appID, !appID.isEmpty else { return "Online" }

        let detail = friend.appDetail.flatMap { $0.isEmpty ? nil : $0 }
        return detail.map { "Playing \(appID) · \($0)" } ?? "Playing \(appID)"
    }

    @MainActor
    private func signIn() async {
        errorMessage = nil
        do {
            try await client.signIn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refresh() async {
        guard client.session != nil else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            try await client.refreshFriends()
        } catch {
            errorMessage = error.localizedDescription
        }

        try? await client.refreshOnlineCounts()
    }
}

struct NextendoPopulationBadge: View {
    let count: Int

    var body: some View {
        Label("\(count)", systemImage: "person.2.fill")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel("\(count) players online")
            .allowsHitTesting(false)
    }
}