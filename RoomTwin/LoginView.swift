import SwiftUI
import UniformTypeIdentifiers

/// The first screen: log in, or make an account, with a username and password.
struct LoginView: View {
    @ObservedObject var account: Account
    @State private var username = ""
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "cube.transparent")
                .font(.system(size: 56))
            Text("RoomTwin")
                .font(.largeTitle.bold())
            Text(creating ? "Make an account to save the objects you scan." : "Log in to scan and furnish your room.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(spacing: 10) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(creating ? .newPassword : .password)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 340)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button(action: submit) {
                Group {
                    if busy { ProgressView() } else { Text(creating ? "Create Account" : "Log In") }
                }
                .frame(maxWidth: 340, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || username.isEmpty || password.isEmpty)
            Button(creating ? "Have an account? Log in" : "New here? Create an account") {
                creating.toggle()
                message = nil
            }
            .font(.footnote)
            Spacer()
            if Account.config == nil {
                Text("Accounts aren't set up in this build: run python3 Accounts/setup_supabase.py on the Mac, then rebuild.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
    }

    private func submit() {
        guard !busy, !username.isEmpty, !password.isEmpty else { return }
        busy = true
        message = nil
        Task {
            do {
                if creating {
                    try await account.signUp(username: username, password: password)
                } else {
                    try await account.signIn(username: username, password: password)
                }
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

/// The account button over the main screen: who's signed in, and logging out.
struct AccountMenu: View {
    @EnvironmentObject private var account: Account
    @State private var choosingDriveFolder = false
    @State private var driveError: String?

    var body: some View {
        Menu {
            Text("Logged in as \(account.session?.username ?? "")")
            if let folder = account.roomDriveFolderName {
                Text("Room storage: Google Drive / \(folder) / RoomTwin")
                Button("Change Google Drive Folder", systemImage: "folder.badge.gearshape") {
                    choosingDriveFolder = true
                }
                Button("Disconnect Room Folder", systemImage: "externaldrive.badge.xmark", role: .destructive) {
                    account.disconnectRoomDriveFolder()
                }
            } else {
                Button("Choose Google Drive Folder", systemImage: "externaldrive.badge.plus") {
                    choosingDriveFolder = true
                }
            }
            Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive, action: account.signOut)
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
        .padding(.leading, 8)
        .padding(.top, 4)
        .fileImporter(isPresented: $choosingDriveFolder, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            do {
                guard let folder = try result.get().first else { return }
                try account.connectRoomDriveFolder(folder)
            } catch {
                driveError = error.localizedDescription
            }
        }
        .alert("Couldn’t use that Google Drive folder", isPresented: Binding(
            get: { driveError != nil }, set: { if !$0 { driveError = nil } }
        )) {
            Button("OK") { driveError = nil }
        } message: {
            Text(driveError ?? "Choose a writable folder under Google Drive in Files.")
        }
    }
}
