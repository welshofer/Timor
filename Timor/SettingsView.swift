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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Spotify App Credentials")
                        .font(.headline)
                    Text("Create a Spotify app at developer.spotify.com to get these credentials")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Client ID") {
                SecureField("Enter your Spotify Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
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
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Save Credentials") {
                        saveCredentials()
                    }
                    .buttonStyle(.borderedProminent)
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
    }

    private func loadCredentials() {
        clientID = spotifyManager.clientID
        clientSecret = spotifyManager.clientSecret
    }

    private func saveCredentials() {
        logger.info("Saving credentials - ClientID length: \(clientID.count), Secret length: \(clientSecret.count)")
        spotifyManager.clientID = clientID
        spotifyManager.clientSecret = clientSecret

        // Verify save worked
        let savedID = spotifyManager.clientID
        let savedSecret = spotifyManager.clientSecret
        logger.info("Verification - Saved ClientID length: \(savedID.count), Saved Secret length: \(savedSecret.count)")

        showingSaveConfirmation = true
    }
}