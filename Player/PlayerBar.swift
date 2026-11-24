import SwiftUI

// MARK: - PlayerBarAppearance

/// Shared observable for views to communicate color scheme to the PlayerBar.
/// Injected via `.environment()` at the app level.
@Observable @MainActor
final class PlayerBarAppearance {
    /// When set, the PlayerBar uses this instead of the system color scheme.
    var colorSchemeOverride: ColorScheme?
}

// MARK: - PlayerBar (iOS)

#if os(iOS)
struct PlayerBar: View {
    @Bindable var viewModel: PlayerViewModel
    var actualColorScheme: ColorScheme = .dark
    @Binding var showFullscreenPlayer: Bool
    @Environment(PlayerBarAppearance.self) private var appearance
    @State private var showErrorDetails = false

    private var effectiveColorScheme: ColorScheme {
        appearance.colorSchemeOverride ?? actualColorScheme
    }

    private var primaryTextColor: Color {
        effectiveColorScheme == .dark ? .white : .black
    }

    private var secondaryTextColor: Color {
        effectiveColorScheme == .dark ? .white.opacity(0.6) : .black.opacity(0.6)
    }

    private var progressFraction: CGFloat {
        let duration = viewModel.duration
        let progress = viewModel.progress
        guard duration.isFinite, duration > 0, progress.isFinite else { return 0 }
        return CGFloat(min(1, max(0, progress / duration)))
    }

    var body: some View {
        HStack(spacing: 12) {
            // Tappable track info area - opens fullscreen player
            Button {
                showFullscreenPlayer = true
            } label: {
                HStack(spacing: 12) {
                    // Thumbnail
                    RemoteImage(url: viewModel.currentTrack?.thumbnailURL?.cardThumbnailURL, placeholder: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "music.note")
                                    .foregroundStyle(secondaryTextColor)
                            }
                    })
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Track info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.currentTrack?.title ?? "Not Playing")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(primaryTextColor)
                            .lineLimit(1)

                        if viewModel.playbackError != nil {
                            Button {
                                showErrorDetails = true
                            } label: {
                                Text("Erreur audio : afficher les détails")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                            }
                            .buttonStyle(.plain)
                        }

                        if let display = viewModel.currentTrack?.artistsDisplay, !display.isEmpty {
                            Text(display)
                                .font(.caption)
                                .foregroundStyle(secondaryTextColor)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.currentTrack == nil)


            // Play/Pause
            Button {
                viewModel.playPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(primaryTextColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            // Next
            Button {
                viewModel.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundStyle(primaryTextColor)
            }
            .buttonStyle(.plain)

            // The Web Player supplies audio; Mixtape keeps the native controls.
            if viewModel.currentPlayerType == .webView {
                Button {
                    viewModel.revealWebPlayer()
                } label: {
                    Image(systemName: "globe")
                        .font(.title3)
                        .foregroundStyle(primaryTextColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Afficher YouTube Music")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.red.opacity(0.17))
                        Capsule().fill(Color.red)
                            .frame(width: geometry.size.width * progressFraction)
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $showErrorDetails) {
            NavigationStack {
                ScrollView {
                    Text(viewModel.playbackError ?? "Aucune erreur audio actuelle")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Diagnostic audio")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fermer") { showErrorDetails = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: viewModel.playbackError ?? "Aucune erreur audio") {
                            Label("Partager", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}


#endif
