//
//  SettingsView.swift
//  Timor
//
//  Settings interface for Spotify credentials
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.timor", category: "settings")

struct SettingsView: View {
    @StateObject private var spotifyManager = SpotifyManager.shared
    @State private var clientID: String = ""
    @State private var clientSecret: String = ""
    @State private var showingSaveConfirmation = false
    @State private var showingSaveError = false
    @State private var saveErrorMessage = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect Timor to Spotify")
                        .font(.headline)
                    // USE-2: guided first-run setup.
                    Group {
                        Text("1. Create an app in the Spotify Developer Dashboard.")
                        Text("2. Add the Redirect URI below to your app's settings.")
                        Text("3. Paste the app's Client ID and Client Secret below.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let dashboard = URL(string: "https://developer.spotify.com/dashboard") {
                        Link("Open Spotify Developer Dashboard", destination: dashboard)
                            .font(.caption)
                    }
                }
            }

            Section("Client ID") {
                // USE-4: the Client ID is public (not a secret), so use a plain TextField
                // — masking it only prevents users from verifying a correct paste.
                TextField("Enter your Spotify Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Your Client ID is not secret — it's safe to display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Client Secret") {
                SecureField("Enter your Spotify Client Secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Required for Web API authentication")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }


            Section("Redirect URI") {
                HStack {
                    Text("timor://spotify-callback")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("timor://spotify-callback", forType: .string)
                        #else
                        UIPasteboard.general.string = "timor://spotify-callback"
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                }
                Text("Add this URI to your Spotify app settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    Button("Save") {
                        saveCredentials()
                    }
                    .disabled(clientID.isEmpty || clientSecret.isEmpty)

                    // USE-3: save and immediately start the OAuth flow.
                    Button("Save & Connect") {
                        saveAndConnect()
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(clientID.isEmpty || clientSecret.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 500, height: 400)
        .padding()
        #else
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveCredentials()
                }
                .disabled(clientID.isEmpty || clientSecret.isEmpty)
            }
        }
        #endif
        .onAppear {
            loadCredentials()
        }
        .alert("Credentials Saved", isPresented: $showingSaveConfirmation) {
            Button("OK") {
                dismiss()
            }
        } message: {
            Text("Your Spotify credentials have been securely saved to the Keychain.")
        }
        .alert("Couldn't Save Credentials", isPresented: $showingSaveError) {
            Button("OK") { }
        } message: {
            Text(saveErrorMessage.isEmpty
                 ? "The credentials could not be saved to the Keychain. Please try again."
                 : saveErrorMessage)
        }
    }

    private func loadCredentials() {
        clientID = spotifyManager.clientID
        clientSecret = spotifyManager.clientSecret
    }

    private func saveCredentials() {
        logger.info("Saving credentials - ClientID length: \(clientID.count), Secret length: \(clientSecret.count)")
        // STAB-3: only confirm success if the Keychain write actually succeeded.
        do {
            try spotifyManager.saveCredentials(clientID: clientID, clientSecret: clientSecret)
            showingSaveConfirmation = true
        } catch {
            logger.error("Failed to save credentials: \(error.localizedDescription, privacy: .public)")
            saveErrorMessage = error.localizedDescription
            showingSaveError = true
        }
    }

    /// USE-3: save credentials and immediately kick off the Spotify OAuth flow.
    private func saveAndConnect() {
        do {
            try spotifyManager.saveCredentials(clientID: clientID, clientSecret: clientSecret)
            dismiss()
            spotifyManager.authenticate()
        } catch {
            logger.error("Failed to save credentials: \(error.localizedDescription, privacy: .public)")
            saveErrorMessage = error.localizedDescription
            showingSaveError = true
        }
    }
}