import SwiftUI

/// The objects you've scanned and saved to your account, from Object mode.
/// Tap one to look at it again; swipe to delete it from the account.
struct SavedObjectsSheet: View {
    /// Opens the object with its picture; the sheet stays up with a spinner
    /// until the model has downloaded.
    let onOpen: (Account.SavedObject, UIImage?) async throws -> Void
    @EnvironmentObject private var account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var objects: [Account.SavedObject]?
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var opening: UUID?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let objects, objects.isEmpty {
                    ContentUnavailableView("Nothing saved yet", systemImage: "shippingbox",
                                           description: Text("Capture an object, then tap Save to My Objects."))
                } else if let objects {
                    List {
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(.red)
                        }
                        ForEach(objects) { object in
                            Button { open(object) } label: { row(object) }
                                .disabled(opening != nil)
                        }
                        .onDelete { rows in
                            for row in rows { delete(objects[row]) }
                        }
                    }
                } else if let message {
                    ContentUnavailableView("Couldn't load your objects", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("My Objects")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(opening != nil)
        .task { await load() }
    }

    private func row(_ object: Account.SavedObject) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = thumbnails[object.id] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "cube").foregroundStyle(.secondary)
                }
            }
            .frame(width: 52, height: 52)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task { await loadThumbnail(object) }
            VStack(alignment: .leading, spacing: 2) {
                Text(object.name).foregroundStyle(.primary)
                Text(object.createdAt.prefix(10)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if opening == object.id {
                ProgressView()
            } else {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
            }
        }
    }

    private func load() async {
        do {
            objects = try await account.objects()
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadThumbnail(_ object: Account.SavedObject) async {
        guard thumbnails[object.id] == nil, let image = await account.thumbnail(for: object) else { return }
        thumbnails[object.id] = image
    }

    private func open(_ object: Account.SavedObject) {
        opening = object.id
        message = nil
        Task {
            do {
                try await onOpen(object, thumbnails[object.id])
                dismiss()
            } catch {
                message = "Couldn't open \(object.name): \(error.localizedDescription)"
            }
            opening = nil
        }
    }

    private func delete(_ object: Account.SavedObject) {
        objects?.removeAll { $0.id == object.id }
        Task {
            do { try await account.delete(object) } catch { await load() }
        }
    }
}
