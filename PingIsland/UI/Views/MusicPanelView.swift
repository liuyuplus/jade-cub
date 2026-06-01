//
//  MusicPanelView.swift
//  PingIsland
//
//  Current music status panel for the island.
//

import AppKit
import SwiftUI

struct MusicPanelView: View {
    @ObservedObject private var store = MusicNowPlayingStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Group {
                if let track = store.track {
                    nowPlayingCard(track)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
        .onAppear { store.start() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text("Music")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            if let source = store.track?.source {
                Text(source)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
            }

            Spacer(minLength: 0)

            Button(action: store.refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Refresh music status")
        }
    }

    private func nowPlayingCard(_ track: MusicNowPlayingTrack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                albumArtwork(for: track)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(track.artist)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if !track.album.isEmpty {
                        Text(track.album)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.36))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                progressBlock(track)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 166, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func albumArtwork(for track: MusicNowPlayingTrack) -> some View {
        if let artworkData = track.artworkData,
           let image = NSImage(data: artworkData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .id("\(track.title)-\(track.artist)-\(artworkData.count)")
        } else if let artworkURL = track.artworkURL {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    albumGlyph(isPlaying: track.isPlaying)
                case .empty:
                    albumGlyph(isPlaying: track.isPlaying)
                @unknown default:
                    albumGlyph(isPlaying: track.isPlaying)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .id("\(track.title)-\(track.artist)-\(artworkURL.absoluteString)")
        } else {
            albumGlyph(isPlaying: track.isPlaying)
        }
    }

    private func albumGlyph(isPlaying: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.09))

            Image(systemName: isPlaying ? "waveform" : "pause.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(width: 52, height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func progressBlock(_ track: MusicNowPlayingTrack) -> some View {
        let position = track.effectivePosition
        let progress = track.duration > 0 ? position / track.duration : 0

        return VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))

                    Capsule()
                        .fill(Color.white.opacity(track.isPlaying ? 0.76 : 0.46))
                        .frame(width: max(4, geometry.size.width * progress))
                }
            }
            .frame(height: 5)

            ZStack(alignment: .top) {
                HStack {
                    Text(formatTime(position))
                    Spacer(minLength: 0)
                    Text(formatTime(track.duration))
                }

                VStack(spacing: 8) {
                    Text(track.isPlaying ? "Playing" : "Paused")
                    playbackControls(for: track)
                }
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
            .monospacedDigit()
            .frame(height: 50, alignment: .top)
        }
    }

    private func playbackControls(for track: MusicNowPlayingTrack) -> some View {
        HStack(spacing: 8) {
            controlButton(
                systemName: "backward.fill",
                help: "Previous track"
            ) {
                store.perform(.previousTrack)
            }

            controlButton(
                systemName: track.isPlaying ? "pause.fill" : "play.fill",
                help: track.isPlaying ? "Pause" : "Play"
            ) {
                store.perform(.togglePlayPause)
            }

            controlButton(
                systemName: "forward.fill",
                help: "Next track"
            ) {
                store.perform(.nextTrack)
            }
        }
    }

    private func controlButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.74))
                .frame(width: 28, height: 24)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))

            Text("Nothing playing")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))

            Text(emptyDetail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(store.diagnostic)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.26))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 138)
    }

    private var emptyDetail: String {
        if store.lastError != nil {
            return "Allow Apple Events access, then try again"
        }
        return "Start Apple Music, Spotify, or NeteaseMusic"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
