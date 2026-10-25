//
//  ScanAnimationView.swift
//  Face ID
//
//  Plays a scan animation once and holds its final frame — deliberately not
//  looping, since each video ends on a meaningful resolved state.
//

import SwiftUI
import AVFoundation
import AppKit

/// Which media the overlay is showing. `.idle` is a still image (the first
/// frame of the success video) so the transition into a playing video is
/// seamless.
enum ScanMedia: Equatable {
    case idle
    case success
    case failure

    var videoResourceName: String? {
        switch self {
        case .idle: return nil
        case .success: return "unlockanimation"
        case .failure: return "unsuccessfulunlockanimation"
        }
    }
}

struct ScanAnimationView: NSViewRepresentable {
    let media: ScanMedia
    /// Fired when the current video plays to its end. Threaded through from the
    /// controller so the success animation can collapse on the video's actual
    /// finish rather than on a fixed clock.
    var onPlaybackCompleted: (() -> Void)?

    func makeNSView(context: Context) -> ScanAnimationHostView {
        let view = ScanAnimationHostView()
        view.onPlaybackCompleted = onPlaybackCompleted
        view.apply(media: media)
        return view
    }

    func updateNSView(_ nsView: ScanAnimationHostView, context: Context) {
        nsView.onPlaybackCompleted = onPlaybackCompleted
        nsView.apply(media: media)
    }
}

final class ScanAnimationHostView: NSView {
    private var player: AVPlayer?
    private let playerLayer = AVPlayerLayer()
    private let stillImageLayer = CALayer()
    private var currentMedia: ScanMedia?
    private var readyObservation: NSKeyValueObservation?
    private var fallbackRevealWorkItem: DispatchWorkItem?
    private var endObserver: NSObjectProtocol?
    /// `play()` is deferred until the layer is actually revealed, so we don't start
    /// counting visible frames before the user can see them.
    private var hasStartedPlayback = false

    /// Called when the current video plays to its end — used by the controller to
    /// time the success-animation collapse to the actual video, not a fixed clock.
    var onPlaybackCompleted: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()

        stillImageLayer.contentsGravity = .resizeAspect
        if let still = Self.loadStillFromBundle() {
            stillImageLayer.contents = still
        }
        layer?.addSublayer(stillImageLayer)

        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        stillImageLayer.frame = bounds
        CATransaction.commit()
    }

    func apply(media: ScanMedia) {
        guard media != currentMedia else { return }
        currentMedia = media
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()
        removeEndObserver()
        hasStartedPlayback = false

        guard let resource = media.videoResourceName else {
            teardownPlayer()
            playerLayer.isHidden = true
            stillImageLayer.isHidden = false
            return
        }

        guard let url = Bundle.main.url(forResource: resource, withExtension: "mp4") else {
            assertionFailure("\(resource).mp4 missing from bundle — check FaceID/Resources/")
            return
        }

        teardownPlayer()
        let newPlayer = AVPlayer(url: url)
        // This can play at the lock screen — never make noise.
        newPlayer.isMuted = true
        // Leaves the player paused on its final frame rather than rewinding.
        newPlayer.actionAtItemEnd = .none

        playerLayer.player = newPlayer
        player = newPlayer

        // Waits for `isReadyForDisplay` rather than a fixed delay, which raced the
        // real decode time and produced a black-frame flash.
        let reveal: () -> Void = { [weak self] in
            guard let self else { return }
            // Without disabling implicit actions, toggling `isHidden` cross-fades both
            // layers over CALayer's default duration instead of swapping instantly.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.playerLayer.isHidden = false
            self.stillImageLayer.isHidden = true
            CATransaction.commit()
            // Only now begin visible playback, from the true first frame, so a slow
            // first-frame decode can't burn the opening beats behind the still image.
            self.startPlaybackIfNeeded()
        }
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                self?.fallbackRevealWorkItem?.cancel()
                reveal()
                self?.readyObservation = nil
            }
        }
        // Safety net only — if isReadyForDisplay never fires for some
        // reason, don't get stuck on the still forever.
        let fallback = DispatchWorkItem { reveal() }
        fallbackRevealWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: fallback)

        // Prepare at the first frame but stay paused until `reveal()` — see above.
        newPlayer.seek(to: .zero)
    }

    /// Begins playback once, from the first frame, and arms the end-of-playback
    /// callback. Called from `reveal()`, which fires on either the real
    /// `isReadyForDisplay` or the 0.6s fallback — whichever lands first.
    private func startPlaybackIfNeeded() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
        guard let player, let item = player.currentItem else { return }
        // Restart from the true first frame so visible playback always begins at the start.
        player.seek(to: .zero)
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onPlaybackCompleted?()
        }
        player.play()
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func teardownPlayer() {
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()
        removeEndObserver()
        hasStartedPlayback = false
        player?.pause()
        player = nil
        playerLayer.player = nil
    }

    /// The asset lives in Resources/ rather than an asset catalog, so
    /// `NSImage(named:)` won't find it — load by URL instead.
    private static func loadStillFromBundle() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "unlockstatic", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
