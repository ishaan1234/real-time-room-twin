import SwiftUI

/// The room layouts you've saved to your account. Tap one to open it in the
/// preview again; swipe to delete it from the account.
struct SavedRoomsSheet: View {
    /// Opens the room; the sheet stays up with a spinner until it's ready.
    let onOpen: (Account.SavedRoomLayout) async throws -> Void
    @EnvironmentObject private var account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var rooms: [Account.SavedRoomLayout]?
    @State private var opening: UUID?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let rooms, rooms.isEmpty {
                    ContentUnavailableView("No saved rooms", systemImage: "square.split.bottomrightquarter",
                                           description: Text("Scan a Room Layout, then tap Save to Account."))
                } else if let rooms {
                    List {
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                        ForEach(rooms) { room in
                            Button { open(room) } label: { row(room) }
                                .disabled(opening != nil)
                        }
                        .onDelete { rows in
                            for row in rows { delete(rooms[row]) }
                        }
                    }
                } else if let message {
                    ContentUnavailableView("Couldn't load your rooms", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Saved Rooms")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(opening != nil)
        .task { await load() }
    }

    private func row(_ room: Account.SavedRoomLayout) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).foregroundStyle(.primary)
                Text(room.createdAt.prefix(10)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if opening == room.id {
                ProgressView()
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            }
        }
    }

    private func load() async {
        do {
            rooms = try await account.roomLayouts()
        } catch {
            message = error.localizedDescription
        }
    }

    private func open(_ room: Account.SavedRoomLayout) {
        opening = room.id
        message = nil
        Task {
            do {
                try await onOpen(room)
                dismiss()
            } catch {
                message = "Couldn't open \(room.name): \(error.localizedDescription)"
            }
            opening = nil
        }
    }

    private func delete(_ room: Account.SavedRoomLayout) {
        rooms?.removeAll { $0.id == room.id }
        Task {
            do { try await account.delete(room) } catch { await load() }
        }
    }
}
