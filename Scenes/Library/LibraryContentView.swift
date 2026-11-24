//
//  LibraryContentView.swift
//  Mixtape
//
//  Content view for Library (Playlists) tab, used with LibraryCoordinator.
//

import SwiftUI
import Observation
import FactoryKit

struct LibraryContentView: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var quickPlaylists = MixtapeQuickPlaylists.shared
    @State private var showCreatePlaylist = false
    @State private var playlistName = ""
    @State private var selectedQuickPlaylist: MixtapeQuickPlaylist?

    private let gridColumns = [GridItem(.adaptive(minimum: .adaptiveGridMinimum - 40, maximum: .adaptiveGridMaximum), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                quickPlaylistsSection
                playlistsSection
                albumsSection
                artistsSection
                downloadsSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .mixtapeScrollAbovePlayer()
        .loading(viewModel.loadingState) {
            viewModel.refresh()
        }
    #if os(iOS)
        .inlineLargeTitle("Library") {
            Button {
                self.viewModel.didRequestSettings()
            } label: {
                UserProfileView(imageSize: 40)
            }
        }
    #else
        .navigationTitle("Library")
    #endif
        .task {
            viewModel.refresh()
        }
        .refreshable {
            viewModel.refresh()
        }
        .alert("Nouvelle playlist", isPresented: $showCreatePlaylist) {
            TextField("Nom de la playlist", text: $playlistName)
            Button("Créer") {
                let newID = quickPlaylists.create(name: playlistName)
                selectedQuickPlaylist = quickPlaylists.playlists.first { $0.id == newID }
                playlistName = ""
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Une playlist peut mélanger musiques téléchargées et titres en streaming.")
        }
        .sheet(item: $selectedQuickPlaylist) { playlist in
            NavigationStack {
                MixtapeQuickPlaylistDetailView(playlistID: playlist.id)
            }
        }
    }

    @ViewBuilder
    private var quickPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Mes playlists Mixtape", systemImage: "square.stack.fill")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    playlistName = ""
                    showCreatePlaylist = true
                } label: {
                    Label("Créer", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
            }
            if quickPlaylists.playlists.isEmpty {
                Text("Crée une playlist puis ajoute des titres depuis Rechercher, le lecteur ou Téléchargements.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                ForEach(quickPlaylists.playlists) { playlist in
                    Button {
                        selectedQuickPlaylist = playlist
                    } label: {
                        HStack(spacing: 12) {
                            MixtapeQuickPlaylistArt(playlist: playlist, size: 66)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(playlist.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text("\(playlist.songs.count) titre(s) · téléchargés et streaming")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(11)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            quickPlaylists.delete(id: playlist.id)
                        } label: {
                            Label("Supprimer la playlist", systemImage: "trash")
                        }
                    }
                }
            }
            if !Container.shared.downloadManager().downloads.isEmpty {
                Button {
                    let songs = Container.shared.downloadManager().downloads.map(\.song)
                    let newID = quickPlaylists.create(name: "Mes téléchargements", songs: songs)
                    selectedQuickPlaylist = quickPlaylists.playlists.first { $0.id == newID }
                } label: {
                    Label("Créer avec tous mes téléchargements", systemImage: "square.and.arrow.down")
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var downloadsSection: some View {
        if viewModel.hasDownloads {
            Button {
                viewModel.didSelectDownloads()
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Downloads")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    downloadsThumbnailRow

                    HStack(spacing: 4) {
                        Text("\(viewModel.downloadCount) songs")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                        Text(viewModel.downloadSizeDisplay)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if viewModel.activeDownloadCount > 0 {
                            Text("·")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                            Text("\(viewModel.activeDownloadCount) downloading")
                                .font(.subheadline)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var downloadsThumbnailRow: some View {
        let thumbnails = viewModel.recentDownloadThumbnails
        if !thumbnails.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, url in
                    RemoteImage(url: url) {
                        Rectangle().fill(.quaternary)
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var playlistsSection: some View {
        sectionHeader("Playlists")
        if viewModel.playlists.isEmpty {
            emptyStateView(icon: "music.note.list", title: "No playlists yet", message: "Create playlists on \(ytmDisplayName) to see them here.")
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(viewModel.playlists) { playlist in
                    Button {
                        viewModel.didSelectPlaylist(playlist)
                    } label: {
                        PlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.interactiveCard)
                    .hoverPlay {
                        Task { await viewModel.playPlaylist(playlist) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        sectionHeader("Albums")
        if viewModel.albums.isEmpty {
            emptyStateView(icon: "square.stack", title: "No albums yet", message: "Save albums on \(ytmDisplayName) to see them here.")
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(viewModel.albums) { album in
                    Button {
                        let playlist = Playlist(
                            id: album.id,
                            title: album.title,
                            description: nil,
                            thumbnailURL: album.thumbnailURL,
                            trackCount: album.trackCount,
                            author: album.artistsDisplay
                        )
                        viewModel.didSelectPlaylist(playlist)
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.interactiveCard)
                    .hoverPlay {
                        Task { await viewModel.playAlbum(album) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var artistsSection: some View {
        sectionHeader("Artists")
        if viewModel.artists.isEmpty {
            emptyStateView(icon: "person.2", title: "No artists yet", message: "Subscribe to artists on \(ytmDisplayName) to see them here.")
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(viewModel.artists) { artist in
                    Button {
                        viewModel.didSelectArtist(artist)
                    } label: {
                        ArtistCard(artist: artist)
                    }
                    .buttonStyle(.interactiveCard)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title2)
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func emptyStateView(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

}

// MARK: - Mixtape local playlists (downloaded and streaming tracks)

struct MixtapeQuickPlaylist: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var songs: [Song]
    var createdAt: Date
}

@MainActor
@Observable
final class MixtapeQuickPlaylists {
    static let shared = MixtapeQuickPlaylists()
    private static let storageKey = "mixtape.localPlaylists.v1"

    private(set) var playlists: [MixtapeQuickPlaylist] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([MixtapeQuickPlaylist].self, from: data) {
            playlists = saved
        }
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(playlists) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.storageKey)
    }

    @discardableResult
    func create(name: String, songs: [Song] = []) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Nouvelle playlist" : trimmed
        let id = UUID()
        let uniqueSongs = songs.reduce(into: [Song]()) { result, song in
            if !result.contains(where: { $0.videoId == song.videoId }) {
                result.append(song)
            }
        }
        playlists.insert(MixtapeQuickPlaylist(id: id, name: title, songs: uniqueSongs, createdAt: Date()), at: 0)
        save()
        return id
    }

    func add(_ song: Song, to playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        guard !playlists[idx].songs.contains(where: { $0.videoId == song.videoId }) else { return }
        playlists[idx].songs.append(song)
        save()
    }

    func remove(videoId: String, from playlistID: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[idx].songs.removeAll { $0.videoId == videoId }
        save()
    }

    /// Reorders songs persistently (does not download, delete or modify audio).
    /// The destination row can receive the song above or below its midpoint.
    func move(videoId: String, near targetID: String, after: Bool, in playlistID: UUID) {
        guard videoId != targetID,
              let idx = playlists.firstIndex(where: { $0.id == playlistID }),
              let source = playlists[idx].songs.firstIndex(where: { $0.videoId == videoId })
        else { return }

        let moved = playlists[idx].songs.remove(at: source)
        guard let target = playlists[idx].songs.firstIndex(where: { $0.videoId == targetID }) else {
            playlists[idx].songs.insert(moved, at: source)
            return
        }
        playlists[idx].songs.insert(moved, at: target + (after ? 1 : 0))
        save()
    }

    /// Native SwiftUI List reorder: preserve all tracks and persist ordering.
    func move(from source: IndexSet, to destination: Int, in playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].songs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = trimmed
        save()
    }

    func delete(id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }
}

/// This menu works with downloaded AND streaming songs, without downloading
/// or requiring the title to be in an existing YouTube Music playlist.
struct MixtapeQuickAddMenu: View {
    let song: Song
    @State private var store = MixtapeQuickPlaylists.shared

    var body: some View {
        Menu {
            ForEach(store.playlists) { playlist in
                Button {
                    store.add(song, to: playlist.id)
                } label: {
                    Label(playlist.name, systemImage: "music.note.list")
                }
            }
            if !store.playlists.isEmpty { Divider() }
            Button {
                _ = store.create(name: "Playlist \(store.playlists.count + 1)", songs: [song])
            } label: {
                Label("Créer une playlist avec ce titre", systemImage: "plus.circle")
            }
        } label: {
            Label("Ajouter à une playlist", systemImage: "text.badge.plus")
        }
    }
}

struct MixtapeQuickPlaylistDetailView: View {
    let playlistID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var store = MixtapeQuickPlaylists.shared
    @State private var showRename = false
    @State private var newName = ""
    // Native List edit mode supplies reliable drag handles on iOS 18.
    @State private var editMode: EditMode = .inactive

    private var playlist: MixtapeQuickPlaylist? {
        store.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        List {
            if let playlist {
                Section {
                    VStack(spacing: 12) {
                        MixtapeQuickPlaylistArt(playlist: playlist, size: 156)
                            .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
                        Text(playlist.name)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text("\(playlist.songs.count) titre(s) · playlist Mixtape")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 14) {
                            Button {
                                guard !playlist.songs.isEmpty else { return }
                                Task {
                                    await Container.shared.playerManager().playQueue(playlist.songs, startingAt: 0)
                                }
                            } label: {
                                Label("Lire", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(playlist.songs.isEmpty)

                            Button {
                                guard !playlist.songs.isEmpty else { return }
                                Task {
                                    await Container.shared.playerManager().playQueue(playlist.songs.shuffled(), startingAt: 0)
                                }
                            } label: {
                                Label("Aléatoire", systemImage: "shuffle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(playlist.songs.isEmpty)
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .listRowBackground(Color.clear)
                }

                if playlist.songs.isEmpty {
                    Section {
                        Text("Aucun titre. Dans Rechercher, maintiens un titre puis sélectionne Ajouter à une playlist.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(Array(playlist.songs.enumerated()), id: \.element.videoId) { index, song in
                            HStack(spacing: 12) {
                                Button {
                                    Task {
                                        await Container.shared.playerManager().playQueue(playlist.songs, startingAt: index)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        RemoteImage(url: song.thumbnailURL) {
                                            RoundedRectangle(cornerRadius: 7)
                                                .fill(.quaternary)
                                                .overlay { Image(systemName: "music.note") }
                                        }
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 52, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(song.title)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            Text(song.artistsDisplay)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)

                                if Container.shared.downloadManager().localFileURL(for: song.videoId) != nil {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("Téléchargé")
                                } else {
                                    Image(systemName: "wifi")
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Streaming")
                                }
                                Menu {
                                    DownloadContextMenuItems(song: song)
                                    Button(role: .destructive) {
                                        store.remove(videoId: song.videoId, from: playlistID)
                                    } label: {
                                        Label("Retirer de la playlist", systemImage: "minus.circle")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityLabel("Options pour \(song.title)")
                                // The system supplies a working drag handle when
                                // Réorganiser is active; avoid a fake static grip.
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .onMove { source, destination in
                            store.move(from: source, to: destination, in: playlistID)
                        }
                    } header: {
                        Text("\(playlist.songs.count) titres")
                    } footer: {
                        if playlist.songs.count > 1 {
                            Text("Touchez Réorganiser, puis maintenez la poignée d'un titre pour le déplacer. L'ordre est enregistré automatiquement.")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .mixtapeScrollAbovePlayer()
        .navigationTitle(playlist?.name ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Fermer") { dismiss() }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(editMode == .active ? "Terminer" : "Réorganiser") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        editMode = editMode == .active ? .inactive : .active
                    }
                }
                .disabled((playlist?.songs.count ?? 0) < 2)
                Button {
                    newName = playlist?.name ?? ""
                    showRename = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .alert("Renommer la playlist", isPresented: $showRename) {
            TextField("Nom", text: $newName)
            Button("Enregistrer") { store.rename(id: playlistID, to: newName) }
            Button("Annuler", role: .cancel) {}
        }
    }
}

// MARK: - Covers for local mixed playlists

private struct MixtapeQuickPlaylistArt: View {
    let playlist: MixtapeQuickPlaylist
    let size: CGFloat

    private var artworks: [URL] {
        Array(playlist.songs.compactMap(\.thumbnailURL).prefix(4))
    }

    private func cover(_ url: URL, dimension: CGFloat) -> some View {
        RemoteImage(url: url) {
            Rectangle().fill(.quaternary)
        }
        .aspectRatio(contentMode: .fill)
        .frame(width: dimension, height: dimension)
        .clipped()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.14))

            if artworks.count == 4 {
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        cover(artworks[0], dimension: (size - 1) / 2)
                        cover(artworks[1], dimension: (size - 1) / 2)
                    }
                    HStack(spacing: 1) {
                        cover(artworks[2], dimension: (size - 1) / 2)
                        cover(artworks[3], dimension: (size - 1) / 2)
                    }
                }
            } else if let first = artworks.first {
                cover(first, dimension: size)
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: size * 0.31, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}
