//
//  SettingsView.swift
//  Mixtape
//
//  Settings view for app configuration.
//

import SwiftUI

// MARK: - SettingsView

/// Main settings view with tabbed navigation.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: SettingsViewModel
    @AppStorage("mixtape.ios18.downloadQuality") private var downloadQuality = "balanced"
    @AppStorage("mixtape.ios18.streamingMode") private var streamingMode = "audio"
    @AppStorage("mixtape.ios18.streamingQuality") private var streamingQuality = "balanced"
    @AppStorage("mixtape.ios18.allowWebFallback") private var allowWebFallback = true
    @AppStorage("mixtape.ios18.lastNativeFallback") private var lastNativeFallback = ""
    @AppStorage("mixtape.ios18.v35.nativeTrace") private var nativeTraceV35 = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - General Section
                
                Section {
                    // Account status
                    HStack {
                        UserProfileView(imageSize: 24, showName: true)
                        Spacer()
                        if viewModel.isLoggedIn {
                            Button("Sign Out") {
                                Task {
                                    await viewModel.signOut()
                                }
                            }
                        } else {
                            Button("Sign In") {
                                viewModel.showLogin()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    
#if os(macOS)
                    // Now Playing Notifications
                    Toggle("Show Now Playing Notifications", isOn: $viewModel.settings.showNowPlayingNotifications)
#endif
                } header: {
                    Text("General")
                }
                
                // MARK: - Content Section
                
                Section {
                    Picker("Language", selection: $viewModel.settings.contentLanguage) {
                        ForEach(ContentLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    
                    Picker("Region", selection: $viewModel.settings.contentRegion) {
                        ForEach(ContentRegion.allCases.sorted { $0.localizedName.localizedCompare($1.localizedName) == .orderedAscending }) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                } header: {
                    Text("Content")
                } footer: {
                    Text("Changes the language and region for music recommendations and content.")
                }
                
                // MARK: - Playback Section
                Section {
                    Picker("Mode de lecture", selection: $streamingMode) {
                        Text("Lecteur natif").tag("audio")
                        Text("Compatibilité Web").tag("web")
                    }
                    Picker("Qualité audio en streaming", selection: $streamingQuality) {
                        Text("Économie (AAC-LC compatible)").tag("economical")
                        Text("Équilibrée (AAC-LC 128 kb/s si disponible)").tag("balanced")
                        Text("Qualité maximale disponible").tag("maximum")
                    }
                    .disabled(streamingMode == "web")
                Toggle("Autoriser le lecteur Web de secours", isOn: $allowWebFallback)
                    .disabled(streamingMode == "web")
                } header: {
                    Text("Lecture en ligne")
                } footer: {
                    Text("Le lecteur natif est utilisé sur Wi-Fi et sur réseau mobile. Le secours Web peut prendre le relais sur le même morceau en cas d’échec. S’applique au prochain titre. Les téléchargements sont lus localement.")
                }

                // MARK: - Offline download quality
                Section {
                    Picker("Qualité du téléchargement", selection: $downloadQuality) {
                        Text("Économie (petit fichier)").tag("economical")
                        Text("Équilibrée (environ 128 kb/s)").tag("balanced")
                        Text("Maximum disponible").tag("maximum")
                    }
                } header: {
                    Text("Téléchargements")
                } footer: {
                    Text("La qualité réelle dépend des formats AAC disponibles. Ce choix s'applique aux prochains téléchargements, pas aux fichiers déjà enregistrés.")
                }

                // MARK: - Native audio events (v35)
                if !nativeTraceV35.isEmpty {
                    Section {
                        Text(nativeTraceV35)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                        ShareLink(item: nativeTraceV35) {
                            Label("Partager le journal audio natif", systemImage: "square.and.arrow.up")
                        }
                        Button("Effacer le journal audio", role: .destructive) {
                            nativeTraceV35 = ""
                        }
                    } header: {
                        Text("Journal audio")
                    } footer: {
                        Text("Heures UTC, profils et statuts réseau, étapes AVPlayer. Aucun cookie ni lien signé n'est enregistré.")
                    }
                }

                // MARK: - Audio diagnostics (iOS 18 compatibility)
                if !lastNativeFallback.isEmpty {
                    Section {
                        Text(lastNativeFallback)
                            .font(.footnote)
                            .textSelection(.enabled)
                        ShareLink(item: lastNativeFallback) {
                            Label("Partager le diagnostic", systemImage: "square.and.arrow.up")
                        }
                    } header: {
                        Text("Dernier échec du lecteur audio seul")
                    } footer: {
                        Text("Une erreur HTTP 403 signifie que le serveur refuse le flux direct. Un délai dépassé peut indiquer un réseau lent ou un chargement bloqué.")
                    }
                }

                // MARK: - About Section
                
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(viewModel.appVersion)
                            .foregroundStyle(.secondary)
                    }
                    
                } header: {
                    Text("About")
                }
                
#if DEBUG
                // MARK: - Debug Section
                
                Section {
                    Button(role: .destructive) {
                        viewModel.resetDefaults()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Reset All Defaults")
                            Spacer()
                        }
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Resets all app settings, saved queue, and account info to defaults.")
                }
#endif
            }
            .formStyle(.grouped)
#if os(iOS)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
#endif
        }
        .sheet(isPresented: $viewModel.showLoginSheet) {
            LoginSheet()
        }
        .onAppear {
            if streamingMode == "auto" { streamingMode = "audio" }
        }
    }
}
