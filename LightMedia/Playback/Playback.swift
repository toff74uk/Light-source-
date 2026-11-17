import UIKit
import AVFoundation
import MobileVLCKit

/// One app-owned video player. Its picture lives in `surface`, which is moved between
/// the preview window and the full-screen player so playback carries on without reloading.
final class PlaybackSession: NSObject, VLCMediaPlayerDelegate {
    static let shared = PlaybackSession()
    static let changed = Notification.Name("LightMediaPlaybackChanged")

    let surface = UIView()
    private(set) var player: VLCMediaPlayer?
    private(set) var item: MediaItem?
    private(set) var failure: String?
    private(set) var ended = false
    private(set) var wantsPlay = true
    private(set) var started = false
    var previewStopped = false

    private var canvas: UIView?
    private var source = ""
    private var ticker: Timer?
    private var ticks = 0
    private var lastTime: Int64 = -1
    private var lastProgress = Date()
    private var backgroundPaused = false
    private var preferenceApplied = false

    private override init() {
        super.init()
        surface.backgroundColor = .black
        surface.isUserInteractionEnabled = false
        surface.clipsToBounds = true
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        centre.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    var active: Bool { return player != nil }

    func same(_ next: MediaItem?) -> Bool {
        guard let item = item, let next = next else { return false }
        return item.id == next.id && item.kind == next.kind
    }

    /// Places the picture inside `host`, behind that host's own controls.
    func attach(to host: UIView) {
        if surface.superview !== host {
            surface.removeFromSuperview()
            host.insertSubview(surface, at: 0)
        }
        surface.frame = host.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    @discardableResult
    func obtain(_ next: MediaItem, provider: Provider?, restart: Bool) -> Bool {
        previewStopped = false
        let store = LocalStore.shared
        let address: String
        if let provider = provider {
            address = provider.streamUrl(next, liveFormat: store.liveFormat)
        } else {
            address = Bundle.main.url(forResource: "demo", withExtension: "mp4")?.absoluteString ?? ""
        }
        if let player = player, same(next), source == address, failure == nil, !ended {
            if restart { seek(to: 0) }
            if !player.isPlaying && wantsPlay { player.play() }
            return true
        }
        stop()
        guard let url = URL(string: address) else {
            failure = "Playback failed. Restart playback to recreate the player."
            notify()
            return false
        }
        item = next
        source = address
        wantsPlay = true
        started = false
        ended = false
        failure = nil
        preferenceApplied = false
        lastTime = -1
        lastProgress = Date()

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let view = UIView(frame: surface.bounds)
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.addSubview(view)
        canvas = view

        guard let media = unwrap(VLCMedia(url: url)) else {
            failure = "Playback failed. Restart playback to recreate the player."
            notify()
            return false
        }
        if provider != nil {
            media.addOption(":http-user-agent=RGTV/2.3")
            media.addOption(":network-caching=1500")
            media.addOption(":http-reconnect")
        }
        if next.kind != .LIVE && !restart {
            let seconds = store.position(next) / 1000
            if seconds > 0 { media.addOption(":start-time=\(seconds)") }
        }
        if provider == nil && next.kind == .LIVE { media.addOption(":input-repeat=65535") }
        let contrast = Prefs.named("subtitles").int("contrast", 0)
        if contrast != 0 {
            media.addOption(":freetype-background-opacity=255")
            media.addOption(":freetype-background-color=0")
        }
        let created = VLCMediaPlayer()
        created.drawable = view
        created.delegate = self
        created.media = media
        player = created
        created.play()

        ticker?.invalidate()
        ticks = 0
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        UIApplication.shared.isIdleTimerDisabled = true
        notify()
        return true
    }

    // MARK: transport

    var positionMs: Int64 {
        let time: VLCTime? = player?.time
        return Int64(time?.intValue ?? 0)
    }
    var durationMs: Int64 {
        let media: VLCMedia? = player?.media
        let length: VLCTime? = media?.length
        return Int64(length?.intValue ?? 0)
    }
    var isPlaying: Bool { return player?.isPlaying ?? false }

    func play() {
        guard let player = player else { return }
        wantsPlay = true
        lastProgress = Date()
        player.play()
        UIApplication.shared.isIdleTimerDisabled = true
        notify()
    }

    func pause() {
        guard let player = player else { return }
        wantsPlay = false
        if player.isPlaying || player.canPause { player.pause() }
        UIApplication.shared.isIdleTimerDisabled = false
        notify()
    }

    func seek(to ms: Int64) {
        guard let player = player else { return }
        let target = max(0, durationMs > 0 ? min(ms, durationMs - 1000) : ms)
        player.time = VLCTime(int: Int32(truncatingIfNeeded: target))
        lastProgress = Date()
    }

    var rate: Float {
        get { return player?.rate ?? 1 }
        set { player?.rate = newValue }
    }

    // MARK: lifecycle

    func save() {
        guard let item = item, player != nil, started, item.kind != .LIVE else { return }
        LocalStore.shared.progress(item, position: ended && durationMs > 0 ? durationMs : positionMs, duration: durationMs)
    }

    func stopPreview() { stop(); previewStopped = true }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        if let old = player {
            save()
            old.delegate = nil
            let oldCanvas = canvas
            DispatchQueue.global(qos: .userInitiated).async {
                old.stop()
                DispatchQueue.main.async { oldCanvas?.removeFromSuperview() }
            }
        }
        canvas = nil
        player = nil
        item = nil
        source = ""
        failure = nil
        ended = false
        started = false
        backgroundPaused = false
        UIApplication.shared.isIdleTimerDisabled = false
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: PlaybackSession.changed, object: self)
    }

    private func tick() {
        guard let player = player else { return }
        ticks += 1
        let time = positionMs
        if time != lastTime {
            lastTime = time
            lastProgress = Date()
            if time > 0 && !started {
                started = true
                notify()
            }
        }
        if started && !preferenceApplied {
            preferenceApplied = true
            PlaybackOptions.applyPreference(player)
        }
        if ticks % 5 == 0 { save() }
        // Report a visible stalled player once; never retry in a loop.
        if wantsPlay && !ended && failure == nil {
            let quiet = Date().timeIntervalSince(lastProgress)
            if !started && quiet >= 30 {
                failure = "Playback is still buffering after 30 seconds.\n\nChoose Restart playback to reconnect."
                notify()
            } else if started && quiet >= 20 {
                failure = "Video output has stalled.\n\nChoose Restart playback to reconnect."
                notify()
            }
        } else if !wantsPlay {
            lastProgress = Date()
        }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let player = self.player else { return }
            switch player.state {
            case .error:
                self.failure = "Playback failed. Restart playback to recreate the player."
            case .ended:
                self.ended = true
                self.save()
            case .playing:
                self.lastProgress = Date()
            default:
                break
            }
            self.notify()
        }
    }

    @objc private func background() {
        guard let player = player else { return }
        save()
        Prefs.flushAll()
        if wantsPlay && player.isPlaying {
            backgroundPaused = true
            player.pause()
        }
    }

    @objc private func foreground() {
        if backgroundPaused, let player = player {
            backgroundPaused = false
            lastProgress = Date()
            player.play()
        }
    }
}

// MARK: - Audio, subtitle and speed choices

/// Source-supplied audio and subtitle tracks.
final class PlaybackOptions {
    private weak var host: UIViewController?
    private let returnFocus: () -> Void
    private var prefs: Prefs { return Prefs.named("subtitles") }
    private var session: PlaybackSession { return PlaybackSession.shared }

    init(host: UIViewController, returnFocus: @escaping () -> Void) {
        self.host = host
        self.returnFocus = returnFocus
    }

    struct Track {
        let index: Int32
        let label: String
    }

    static func tracks(names: [Any]?, indexes: [Any]?) -> [Track] {
        guard let names = names, let indexes = indexes else { return [] }
        var out: [Track] = []
        for (n, raw) in indexes.enumerated() where n < names.count {
            let index = (raw as? NSNumber)?.int32Value ?? -1
            if index < 0 { continue }
            let name = (names[n] as? String) ?? "Track \(n)"
            out.append(Track(index: index, label: name))
        }
        return out
    }

    private static func send(_ player: VLCMediaPlayer, _ selector: String, _ value: NSNumber) {
        let sel = NSSelectorFromString(selector)
        if player.responds(to: sel) { _ = player.perform(sel, with: value) }
    }

    static func applyAppearance(_ player: VLCMediaPlayer) {
        let prefs = Prefs.named("subtitles")
        let sizes = [20, 16, 12, 9]
        let size = max(0, min(3, prefs.int("size", 1)))
        send(player, "setTextRendererFontSize:", NSNumber(value: sizes[size]))
        send(player, "setTextRendererFontColor:", NSNumber(value: prefs.int("contrast", 0) == 2 ? 0xffff00 : 0xffffff))
    }

    /// Runs once per video, when its tracks are known.
    static func applyPreference(_ player: VLCMediaPlayer) {
        let prefs = Prefs.named("subtitles")
        applyAppearance(player)
        let subtitles = tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
        switch prefs.string("mode", "auto") {
        case "off":
            player.currentVideoSubTitleIndex = -1
        case "language":
            let wanted = prefs.string("language", "").lowercased()
            if let match = subtitles.first(where: { !wanted.isEmpty && $0.label.lowercased() == wanted })
                ?? subtitles.first(where: { !wanted.isEmpty && $0.label.lowercased().contains(wanted) }) {
                player.currentVideoSubTitleIndex = match.index
            }
        default:
            let code = Locale.current.languageCode ?? "en"
            let name = (Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "").lowercased()
            if !name.isEmpty, let match = subtitles.first(where: { $0.label.lowercased().contains(name) }) {
                player.currentVideoSubTitleIndex = match.index
            }
        }
        let audio = prefs.string("audio_language", "").lowercased()
        if !audio.isEmpty {
            let available = tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
            if let match = available.first(where: { $0.label.lowercased() == audio }) {
                player.currentAudioTrackIndex = match.index
            }
        }
    }

    func show() {
        guard let host = host, session.player != nil else { return }
        Ui.choose(host, title: "Playback settings", items: ["Audio options", "Subtitles", "Playback speed"],
                  cancel: "Close", onClose: { [weak self] in self?.settle() }, action: { [weak self] n in
            if n == 0 { self?.showAudio() } else if n == 1 { self?.showSubtitles() } else { self?.showSpeed() }
        })
    }

    /// Hand control back to the player once the last dialog has gone.
    private func settle() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let host = self.host, host.presentedViewController == nil else { return }
            self.returnFocus()
        }
    }

    private func showSpeed() {
        guard let host = host, session.player != nil else { return }
        let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2]
        var selected = 3
        for (n, s) in speeds.enumerated() where abs(session.rate - s) < 0.01 { selected = n }
        Ui.choose(host, title: "Playback speed",
                  items: ["0.25×", "0.5×", "0.75×", "Normal", "1.25×", "1.5×", "2×"],
                  selected: selected, cancel: "Back", cancelAction: { [weak self] in self?.show() },
                  onClose: { [weak self] in self?.settle() }, action: { [weak self] n in
            self?.session.rate = speeds[n]
        })
    }

    private func showAudio() {
        guard let host = host, let player = session.player else { return }
        let available = PlaybackOptions.tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
        if available.isEmpty {
            Ui.message(host, title: "Audio options",
                       message: "No supported audio tracks are available yet. Start playback, then check again.",
                       ok: "Back") { [weak self] in self?.show() }
            return
        }
        let current = player.currentAudioTrackIndex
        let chosen = available.firstIndex(where: { $0.index == current }) ?? -1
        Ui.choose(host, title: available.count == 1 ? "Audio options · one soundtrack" : "Audio options",
                  items: available.map { $0.label }, selected: chosen, cancel: "Back",
                  cancelAction: { [weak self] in self?.show() },
                  onClose: { [weak self] in self?.settle() }, action: { [weak self] n in
            self?.prefs.putString("audio_language", available[n].label)
            self?.session.player?.currentAudioTrackIndex = available[n].index
        })
    }

    func showSubtitles() {
        guard let host = host, let player = session.player else { return }
        let available = PlaybackOptions.tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
        let current = player.currentVideoSubTitleIndex
        var selected = prefs.string("mode", "auto") == "off" || current < 0 ? 0 : 1
        if prefs.string("mode", "auto") == "auto" && selected == 0 { selected = 1 }
        if prefs.string("mode", "auto") == "language", let at = available.firstIndex(where: { $0.index == current }) {
            selected = at + 2
        }
        let picker = PickerViewController()
        picker.heading = available.isEmpty ? "Subtitles · no tracks available" : "Subtitles"
        picker.rows = ["Off", "Automatic · device language"] + available.map { $0.label }
        picker.selected = selected
        picker.onPick = { [weak self] n in self?.choose(n, available) }
        let openAppearance: () -> Void = { [weak self] in self?.appearance() }
        picker.buttons = [("Text appearance", openAppearance), ("Done", nil)]
        picker.onClose = { [weak self] in self?.settle() }
        host.present(picker, animated: true)
    }

    private func choose(_ choice: Int, _ available: [Track]) {
        guard let player = session.player else { return }
        if choice < 2 {
            prefs.putString("mode", choice == 0 ? "off" : "auto")
            if choice == 0 { player.currentVideoSubTitleIndex = -1 } else { PlaybackOptions.applyPreference(player) }
            return
        }
        let track = available[choice - 2]
        prefs.putString("mode", "language")
        prefs.putString("language", track.label)
        player.currentVideoSubTitleIndex = track.index
    }

    private func appearance() {
        guard let host = host else { return }
        Ui.choose(host, title: "Subtitle appearance",
                  items: ["Text size", "Text contrast", "Reset appearance"], cancel: "Back",
                  cancelAction: { [weak self] in self?.showSubtitles() },
                  onClose: { [weak self] in self?.settle() }, action: { [weak self] n in
            guard let self = self else { return }
            if n == 0 { self.size() } else if n == 1 { self.contrast() } else {
                self.prefs.remove("size"); self.prefs.remove("contrast"); self.applyAppearance()
            }
        })
    }

    private func size() {
        guard let host = host else { return }
        Ui.choose(host, title: "Subtitle text size", items: ["Small", "Standard", "Large", "Extra large"],
                  selected: prefs.int("size", 1), cancel: "Back",
                  cancelAction: { [weak self] in self?.appearance() },
                  onClose: { [weak self] in self?.settle() }, action: { [weak self] n in
            self?.prefs.putInt("size", n); self?.applyAppearance()
        })
    }

    private func contrast() {
        guard let host = host else { return }
        Ui.choose(host, title: "Subtitle text contrast",
                  items: ["White with outline", "White on black", "Yellow on black"],
                  selected: prefs.int("contrast", 0), cancel: "Back",
                  cancelAction: { [weak self] in self?.appearance() },
                  onClose: { [weak self] in self?.settle() }, action: { [weak self] n in
            self?.prefs.putInt("contrast", n); self?.applyAppearance()
            Ui.toast("The background change applies from the next video.")
        })
    }

    private func applyAppearance() {
        if let player = session.player { PlaybackOptions.applyAppearance(player) }
    }
}

// MARK: - Preview window

/// The small picture in the browser header. Owned by the main screen, never by a guide row.
final class LivePreviewView: UIView {
    private let host = UIView()
    private let label = UILabel()
    private let stopButton = LMButton("■ Stop", size: 10)
    private var remembered: MediaItem?
    private var session: PlaybackSession { return PlaybackSession.shared }
    var onChanged: (() -> Void)?
    var onOpen: (() -> Void)?
    var onStopped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Ui.bg
        clipsToBounds = true
        host.backgroundColor = Ui.bg
        addSubview(host)
        label.text = "Choose a channel"
        label.font = Ui.font(10)
        label.textColor = .white
        label.shadowColor = .black
        label.shadowOffset = CGSize(width: 0, height: 1)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        stopButton.plain = true
        stopButton.whiteText = true
        stopButton.titleLabel?.shadowColor = .black
        stopButton.titleLabel?.shadowOffset = CGSize(width: 0, height: 1)
        stopButton.contentVerticalAlignment = .bottom
        stopButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 5, right: 0)
        stopButton.accessibilityLabel = "Stop preview playback"
        stopButton.isEnabled = false
        stopButton.action = { [weak self] in self?.stopPlayback() }
        addSubview(stopButton)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        NotificationCenter.default.addObserver(self, selector: #selector(sessionChanged),
                                               name: PlaybackSession.changed, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    static func phoneWidth(screenWidth: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let width = max(184, min(240, (screenWidth * 0.30).rounded()))
        // Keep space for the guide on short landscape displays.
        return min(width, max(160, ((screenHeight * 0.48 - 56) * 16 / 9).rounded(.down)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        host.frame = bounds
        if session.surface.superview === host { session.surface.frame = host.bounds }
        label.frame = CGRect(x: 6, y: bounds.height - 22, width: max(0, bounds.width - 6 - 60), height: 17)
        stopButton.frame = CGRect(x: bounds.width - 56, y: bounds.height - 48, width: 56, height: 48)
    }

    @objc private func tapped() { if session.active { onOpen?() } }

    @objc private func sessionChanged() {
        if let message = session.failure, session.surface.superview === host {
            label.text = message.components(separatedBy: "\n").first
        }
        onChanged?()
    }

    func item() -> MediaItem? {
        if let current = session.item { return current }
        return session.previewStopped ? nil : remembered
    }

    var active: Bool { return session.active && session.failure == nil }
    var canStop: Bool { return session.active }
    func same(_ other: MediaItem) -> Bool { return session.same(other) }

    func select(_ next: MediaItem, _ provider: Provider?) {
        if session.failure != nil && session.same(next) { session.stop() }
        remembered = next
        session.obtain(next, provider: provider, restart: false)
        resume(provider)
    }

    func resume(_ provider: Provider?) {
        if session.previewStopped && !session.active { remembered = nil }
        if !session.active, let item = remembered { session.obtain(item, provider: provider, restart: false) }
        if session.active { session.attach(to: host) }
        let title = session.item?.name ?? ""
        accessibilityLabel = title.isEmpty ? "Preview stopped. Choose a channel." : title + ", open full screen"
        if session.failure == nil { label.text = title.isEmpty ? "Choose a channel" : title }
        stopButton.isEnabled = session.active
        onChanged?()
    }

    func remember(_ next: MediaItem) {
        if !session.active && !session.previewStopped { remembered = next }
    }

    /// Explicit user action: release playback, including audio, and forget the preview selection.
    func stopPlayback() {
        session.stopPreview()
        remembered = nil
        stopButton.isEnabled = false
        label.text = "Preview stopped"
        accessibilityLabel = "Preview stopped. Choose a channel to play."
        onChanged?()
        onStopped?()
    }
}
