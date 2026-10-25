import SwiftUI

enum ObjectLibrarySelection {
    case saved(Account.SavedObject)
    case sketchfab(Sketchfab.Model)

    var name: String {
        switch self {
        case .saved(let object): object.name
        case .sketchfab(let model): model.name
        }
    }
}

/// The bottom Add panel. My Library contains the user's own scans/imports;
/// Sketchfab shows only five suggestions or five search results at a time.
/// A normal tap uses automatic placement. Holding briefly and dragging sends
/// live scene coordinates to ScanPreview for direct drop placement.
struct MyObjectsSheet: View {
    let onPick: (ObjectLibrarySelection) -> Void
    let onDragChanged: (ObjectLibrarySelection, CGPoint) -> Void
    let onDragEnded: (ObjectLibrarySelection, CGPoint) -> Void
    let onClose: () -> Void

    private enum Library: String, CaseIterable, Identifiable {
        case mine = "My Library"
        case sketchfab = "Sketchfab"
        var id: Self { self }
    }

    @EnvironmentObject private var account: Account
    @State private var library = Library.mine
    @State private var objects: [Account.SavedObject]?
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var myMessage: String?
    @State private var sketchfabModels: [Sketchfab.Model]?
    @State private var sketchfabMessage: String?
    @State private var search = ""
    @State private var loadingSketchfab = false

    var body: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(.secondary.opacity(0.55))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
            HStack {
                Text("Add Object").font(.headline)
                Spacer()
                Text("Hold and drag into the room")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            Picker("Library", selection: $library) {
                ForEach(Library.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            switch library {
            case .mine:
                myLibrary
            case .sketchfab:
                sketchfabLibrary
            }
        }
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
        .shadow(color: .black.opacity(0.35), radius: 14, y: -3)
        .task {
            await loadMyObjects()
            await loadSuggestions()
        }
    }

    @ViewBuilder
    private var myLibrary: some View {
        if let objects, objects.isEmpty {
            ContentUnavailableView("Nothing saved yet", systemImage: "shippingbox",
                                   description: Text("Scan or import an object, then save it to My Library."))
        } else if let objects {
            List {
                ForEach(objects) { object in
                    libraryRow(.saved(object)) { myRow(object) }
                }
                .onDelete { rows in
                    for row in rows { delete(objects[row]) }
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
        } else if let myMessage {
            ContentUnavailableView("Couldn't load My Library", systemImage: "exclamationmark.triangle",
                                   description: Text(myMessage))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sketchfabLibrary: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search 3D models", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { Task { await searchSketchfab() } }
                Button("Search", systemImage: "magnifyingglass") {
                    Task { await searchSketchfab() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                Button("Random five", systemImage: "shuffle") {
                    search = ""
                    Task { await loadSuggestions() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)

            if loadingSketchfab {
                ProgressView(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? "Finding five models…" : "Searching Sketchfab…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sketchfabModels, sketchfabModels.isEmpty {
                ContentUnavailableView("No downloadable models", systemImage: "magnifyingglass",
                                       description: Text("Try a broader search such as chair, lamp, or plant."))
            } else if let sketchfabModels {
                List(sketchfabModels.prefix(5)) { model in
                    libraryRow(.sketchfab(model)) { sketchfabRow(model) }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            } else if let sketchfabMessage {
                ContentUnavailableView("Couldn't reach Sketchfab", systemImage: "wifi.exclamationmark",
                                       description: Text(sketchfabMessage))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func libraryRow<Content: View>(_ selection: ObjectLibrarySelection,
                                           @ViewBuilder content: () -> Content) -> some View {
        content()
            .contentShape(Rectangle())
            .onTapGesture { onPick(selection) }
            .gesture(
                LongPressGesture(minimumDuration: 0.16)
                    .sequenced(before: DragGesture(minimumDistance: 1, coordinateSpace: .global))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value else { return }
                        onDragChanged(selection, drag.location)
                    }
                    .onEnded { value in
                        guard case .second(true, let drag?) = value else { return }
                        onDragEnded(selection, drag.location)
                    }
            )
    }

    private func myRow(_ object: Account.SavedObject) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = thumbnails[object.id] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "cube").foregroundStyle(.secondary)
                }
            }
            .frame(width: 56, height: 56)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .task { await loadThumbnail(object) }
            VStack(alignment: .leading, spacing: 2) {
                Text(object.name).foregroundStyle(.primary)
                Text(object.createdAt.prefix(10)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "hand.draw").foregroundStyle(.tint)
        }
    }

    private func sketchfabRow(_ model: Sketchfab.Model) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: model.thumbnailURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "cube.transparent").foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 56)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).foregroundStyle(.primary).lineLimit(2)
                Text("by \(model.author) · \(model.license)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "hand.draw").foregroundStyle(.tint)
        }
    }

    private func loadMyObjects() async {
        do {
            objects = try await account.objects()
            myMessage = nil
        } catch {
            myMessage = error.localizedDescription
        }
    }

    private func loadSuggestions() async {
        loadingSketchfab = true
        sketchfabMessage = nil
        do {
            sketchfabModels = try await Sketchfab.suggestions()
        } catch {
            sketchfabModels = nil
            sketchfabMessage = error.localizedDescription
        }
        loadingSketchfab = false
    }

    private func searchSketchfab() async {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await loadSuggestions()
            return
        }
        loadingSketchfab = true
        sketchfabMessage = nil
        do {
            sketchfabModels = Array(try await Sketchfab.models(matching: query).prefix(5))
        } catch {
            sketchfabModels = nil
            sketchfabMessage = error.localizedDescription
        }
        loadingSketchfab = false
    }

    private func loadThumbnail(_ object: Account.SavedObject) async {
        guard thumbnails[object.id] == nil, let image = await account.thumbnail(for: object) else { return }
        thumbnails[object.id] = image
    }

    private func delete(_ object: Account.SavedObject) {
        objects?.removeAll { $0.id == object.id }
        Task {
            do { try await account.delete(object) } catch { await loadMyObjects() }
        }
    }
}
