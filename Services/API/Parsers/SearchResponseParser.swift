import Foundation

/// Parser for search responses from the API.
enum SearchResponseParser {
    /// Parses mixed YouTube Music search results across supported renderer layouts.
    /// The result can be nested under tabs, shelves and Top Result cards.
    static func parse(_ data: [String: Any]) -> SearchResponse {
        var songs: [Song] = []
        var albums: [Album] = []
        var artists: [Artist] = []
        var playlists: [Playlist] = []
        var seen = Set<String>()

        func append(_ item: SearchResultItem?) {
            guard let item, seen.insert(item.id).inserted else { return }
            switch item {
            case let .song(song): songs.append(song)
            case let .album(album): albums.append(album)
            case let .artist(artist): artists.append(artist)
            case let .playlist(playlist): playlists.append(playlist)
            }
        }

        // Follow only known navigation/result keys; avoid walking unrelated
        // metadata, authentication and menu trees.
        func visit(_ node: Any, depth: Int) {
            guard depth < 18 else { return }
            if let nodes = node as? [Any] {
                for child in nodes { visit(child, depth: depth + 1) }
                return
            }
            guard let object = node as? [String: Any] else { return }

            if let card = object["musicCardShelfRenderer"] as? [String: Any] {
                append(parseCardShelfRenderer(card) ?? parseSongCardRenderer(card))
            }
            if object["musicResponsiveListItemRenderer"] != nil {
                append(parseSearchResultItem(object))
            }
            if let twoRow = object["musicTwoRowItemRenderer"] as? [String: Any] {
                append(parseTwoRowRenderer(twoRow))
            }

            for key in ["tabbedSearchResultsRenderer", "tabs", "tabRenderer",
                        "content", "sectionListRenderer", "contents",
                        "itemSectionRenderer", "musicShelfRenderer",
                        "musicCardShelfRenderer", "musicCarouselShelfRenderer",
                        "gridRenderer", "items"] {
                if let child = object[key] {
                    visit(child, depth: depth + 1)
                }
            }
        }

        visit(data["contents"] ?? data, depth: 0)
        return SearchResponse(songs: songs, albums: albums, artists: artists, playlists: playlists)
    }

    /// Top Result may be a directly playable song rather than a browse item.
    private static func parseSongCardRenderer(_ card: [String: Any]) -> SearchResultItem? {
        guard let titleData = card["title"] as? [String: Any],
              let titleRuns = titleData["runs"] as? [[String: Any]],
              let first = titleRuns.first,
              let title = first["text"] as? String,
              let endpoint = first["navigationEndpoint"] as? [String: Any],
              let watchEndpoint = endpoint["watchEndpoint"] as? [String: Any],
              let videoId = watchEndpoint["videoId"] as? String
        else { return nil }

        let thumbnails = ParsingHelpers.extractThumbnails(from: card)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let song = Song(id: videoId, title: title, artists: [], album: nil,
                        duration: nil, thumbnailURL: thumbnailURL, videoId: videoId)
        return .song(song)
    }

    /// Albums and playlists may appear as two-row cards in newer responses.
    private static func parseTwoRowRenderer(_ renderer: [String: Any]) -> SearchResultItem? {
        guard let title = ParsingHelpers.extractTitle(from: renderer),
              let endpoint = renderer["navigationEndpoint"] as? [String: Any],
              let browse = endpoint["browseEndpoint"] as? [String: Any],
              let browseId = browse["browseId"] as? String
        else { return nil }

        let thumbnails = ParsingHelpers.extractThumbnails(from: renderer)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let pageType = extractPageType(from: browse)
        if pageType == "MUSIC_PAGE_TYPE_ALBUM" || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            return .album(Album(id: browseId, title: title, artists: nil,
                                thumbnailURL: thumbnailURL, year: nil, trackCount: nil))
        }
        if pageType == "MUSIC_PAGE_TYPE_ARTIST" || browseId.hasPrefix("UC") {
            return .artist(Artist(id: browseId, name: title, thumbnailURL: thumbnailURL))
        }
        if pageType == "MUSIC_PAGE_TYPE_PLAYLIST" || browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
            return .playlist(Playlist(id: browseId, title: title, description: nil,
                                      thumbnailURL: thumbnailURL, trackCount: nil, author: nil))
        }
        return nil
    }

    /// Parses a filtered songs-only search response.
    /// Filtered searches have a simpler structure without tabs.
    static func parseSongsOnly(_ data: [String: Any]) -> [Song] {
        var songs: [Song] = []

        // Filtered search has a simpler structure - no tabs
        guard let contents = data["contents"] as? [String: Any],
              let sectionListRenderer = contents["sectionListRenderer"] as? [String: Any],
              let sectionContents = sectionListRenderer["contents"] as? [[String: Any]]
        else {
            // Try tabbed structure as fallback
            let response = self.parse(data)
            return response.songs
        }

        for sectionData in sectionContents {
            if let shelfRenderer = sectionData["musicShelfRenderer"] as? [String: Any],
               let shelfContents = shelfRenderer["contents"] as? [[String: Any]]
            {
                for itemData in shelfContents {
                    if let item = parseSearchResultItem(itemData),
                       case let .song(song) = item
                    {
                        songs.append(song)
                    }
                }
            }
        }

        return songs
    }

    // MARK: - Item Parsing

    /// Parses a musicCardShelfRenderer (Top Result section).
    /// This renderer contains a single prominent result with title, subtitle, and browse endpoint.
    private static func parseCardShelfRenderer(_ data: [String: Any]) -> SearchResultItem? {
        // Extract title and navigation from the title runs
        guard let titleData = data["title"] as? [String: Any],
              let runs = titleData["runs"] as? [[String: Any]],
              let firstRun = runs.first,
              let title = firstRun["text"] as? String,
              let navigationEndpoint = firstRun["navigationEndpoint"] as? [String: Any],
              let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
              let browseId = browseEndpoint["browseId"] as? String
        else {
            return nil
        }

        // Extract thumbnail
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }

        // Extract subtitle
        var subtitle: String?
        if let subtitleData = data["subtitle"] as? [String: Any],
           let subtitleRuns = subtitleData["runs"] as? [[String: Any]]
        {
            subtitle = subtitleRuns.compactMap { $0["text"] as? String }.joined()
        }

        // Extract pageType for accurate type detection
        let pageType = self.extractPageType(from: browseEndpoint)

        // Determine type based on pageType first, then fall back to browseId prefix
        if pageType == "MUSIC_PAGE_TYPE_ALBUM" || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
            let album = Album(
                id: browseId,
                title: title,
                artists: nil,
                thumbnailURL: thumbnailURL,
                year: nil,
                trackCount: nil
            )
            return .album(album)
        } else if pageType == "MUSIC_PAGE_TYPE_ARTIST" || pageType == "MUSIC_PAGE_TYPE_USER_CHANNEL" || browseId.hasPrefix("UC") {
            let artist = Artist(id: browseId, name: title, thumbnailURL: thumbnailURL)
            return .artist(artist)
        } else if pageType == "MUSIC_PAGE_TYPE_PLAYLIST" || browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
            let playlist = Playlist(
                id: browseId,
                title: title,
                description: nil,
                thumbnailURL: thumbnailURL,
                trackCount: nil,
                author: subtitle
            )
            return .playlist(playlist)
        }

        return nil
    }

    private static func parseSearchResultItem(_ data: [String: Any]) -> SearchResultItem? {
        guard let responsiveRenderer = data["musicResponsiveListItemRenderer"] as? [String: Any] else {
            return nil
        }

        // Video IDs can also be in watchEndpoint or thumbnail overlay.
        if let videoId = ParsingHelpers.extractVideoId(from: responsiveRenderer)
        {
            return self.parseSongFromResponsiveRenderer(responsiveRenderer, videoId: videoId)
        }

        // Check navigation endpoint for other types
        if let navigationEndpoint = responsiveRenderer["navigationEndpoint"] as? [String: Any],
           let browseEndpoint = navigationEndpoint["browseEndpoint"] as? [String: Any],
           let browseId = browseEndpoint["browseId"] as? String
        {
            let thumbnails = ParsingHelpers.extractThumbnails(from: responsiveRenderer)
            let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
            let title = ParsingHelpers.extractTitleFromFlexColumns(responsiveRenderer) ?? "Unknown"
            let subtitle = ParsingHelpers.extractSubtitleFromFlexColumns(responsiveRenderer)

            // Extract pageType from browseEndpointContextSupportedConfigs for accurate type detection
            let pageType = self.extractPageType(from: browseEndpoint)

            // Determine type based on pageType first, then fall back to browseId prefix
            if pageType == "MUSIC_PAGE_TYPE_ALBUM" || browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                let album = Album(
                    id: browseId,
                    title: title,
                    artists: nil,
                    thumbnailURL: thumbnailURL,
                    year: nil,
                    trackCount: nil
                )
                return .album(album)
            } else if pageType == "MUSIC_PAGE_TYPE_ARTIST" || pageType == "MUSIC_PAGE_TYPE_USER_CHANNEL" || browseId.hasPrefix("UC") {
                let artist = Artist(id: browseId, name: title, thumbnailURL: thumbnailURL)
                return .artist(artist)
            } else if pageType == "MUSIC_PAGE_TYPE_PLAYLIST" || browseId.hasPrefix("VL") || browseId.hasPrefix("PL") {
                let playlist = Playlist(
                    id: browseId,
                    title: title,
                    description: nil,
                    thumbnailURL: thumbnailURL,
                    trackCount: nil,
                    author: subtitle
                )
                return .playlist(playlist)
            }
        }

        return nil
    }

    // MARK: - Helpers

    private static func extractPageType(from browseEndpoint: [String: Any]) -> String? {
        if let contextConfigs = browseEndpoint["browseEndpointContextSupportedConfigs"] as? [String: Any],
           let musicConfig = contextConfigs["browseEndpointContextMusicConfig"] as? [String: Any],
           let type = musicConfig["pageType"] as? String
        {
            return type
        }
        return nil
    }

    private static func parseSongFromResponsiveRenderer(
        _ data: [String: Any],
        videoId: String
    ) -> SearchResultItem? {
        let thumbnails = ParsingHelpers.extractThumbnails(from: data)
        let thumbnailURL = thumbnails.last.flatMap { URL(string: $0) }
        let title = ParsingHelpers.extractTitleFromFlexColumns(data) ?? "Unknown"
        let artists = ParsingHelpers.extractArtistsFromFlexColumns(data)
        let album = ParsingHelpers.extractAlbumFromFlexColumns(data)
        let videoType = ParsingHelpers.extractVideoType(from: data)

        let song = Song(
            id: videoId,
            title: title,
            artists: artists,
            album: album,
            duration: nil,
            thumbnailURL: thumbnailURL,
            videoId: videoId,
            videoType: videoType
        )
        return .song(song)
    }
}
