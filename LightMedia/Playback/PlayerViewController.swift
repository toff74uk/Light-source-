import UIKit

extension Icons {
    static func image(_ name: String, size: CGFloat, colour: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            Icons.draw(context.cgContext, colour, name, x: 0, y: 0, size: size)
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// Where a live channel was opened from, so channel switching stays inside that list.
struct LiveContext {
    var favourites = false
    var group = ""
    var category: String?
    var query = ""
    var channels: [MediaItem]?
}

/// Full-screen playback for live channels, films and episodes.
final class PlayerViewController: BaseViewController {
    private var item: MediaItem
    private let provider: Provider?
    private var restart: Bool
    private let live: LiveContext
    var onFinish: ((MediaItem) -> Void)?

    private let store = LocalStore.shared
    private var session: PlaybackSession { return PlaybackSession.shared }
    private var options: PlaybackOptions!

    private let host = UIView()
    private let touchLayer = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleBar = GradientView()
    private let titleLabel = Ui.label("", 17, .white, lines: 1)
    private let backButton = LMButton("‹ Back to menu")
    private let settingsButton = LMButton("Settings")
    private let nextButton = LMButton("Next episode ›")

    // Film and episode transport
    private let bottomBar = GradientView()
    private let playPause = IconButton(label: "Pause", icon: "pause", size: 30, action: {})
    private let rewind = LMButton("−10s", size: 13)
    private let forward = LMButton("+30s", size: 13)
    private let elapsed = Ui.label("0:00", 12, .white, lines: 1)
    private let remaining = Ui.label("0:00", 12, .white, lines: 1)
    private let scrubber = UISlider()
    private var scrubbing = false
    private var controlsVisible = false

    // Live controls
    private let liveBar = UIView()
    private var previousChannel: IconButton!
    private var channelList: IconButton!
    private var nextChannel: IconButton!
    private var lastChannelButton: IconButton!
    private var playbackButton: IconButton!
    private var livePause: IconButton!
    private var lastChannel: MediaItem?
    private var channels: [MediaItem] = []
    private var channelsLoaded = false
    private var channelsLoading = false
    private var channelGeneration = 0

    // Failure panel
    private let errors = UIView()
    private let errorLabel = Ui.label("", 15, nil, lines: 0)
    private let retryButton = LMButton("Restart playback")
    private let leaveButton = LMButton("Back to browsing")

    private var hideWork: DispatchWorkItem?
    private var refreshTimer: Timer?
    private var nextLoading = false
    private var nextGeneration = 0
    private var episodeCache: [Int: [MediaItem]]?
    private var endHandled = false
    private var closed = false

    init(item: MediaItem, provider: Provider?, restart: Bool, live: LiveContext = LiveContext()) {
        self.item = item
        self.provider = provider
        self.restart = restart
        self.live = live
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var idleAllowed: Bool { return false }
    private var isLive: Bool { return item.kind == .LIVE }
    private var titleText: String { return item.name + (provider == nil ? "  ·  DEMO" : "") }

    // MARK: setup

    override func viewDidLoad() {
        super.viewDidLoad()
        backdrop.isHidden = true
        view.backgroundColor = .black
        options = PlaybackOptions(host: self) { [weak self] in
            guard let self = self else { return }
            if self.isLive { self.showLiveControls() } else { self.showControls() }
        }

        host.backgroundColor = .black
        view.addSubview(host)
        touchLayer.backgroundColor = .clear
        touchLayer.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(screenTapped)))
        view.addSubview(touchLayer)
        spinner.color = .white
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        titleBar.set([UIColor(argb: 0xb8000000), UIColor(argb: 0x00000000)], diagonal: false)
        titleBar.isUserInteractionEnabled = false
        titleBar.isHidden = true
        view.addSubview(titleBar)
        titleLabel.text = titleText
        titleBar.addSubview(titleLabel)

        settingsButton.setImage(Icons.image("settings", size: 20, colour: Ui.text), for: .normal)
        settingsButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        settingsButton.action = { [weak self] in self?.cancelHide(); self?.options.show() }
        settingsButton.accessibilityLabel = "Playback settings"
        nextButton.action = { [weak self] in self?.nextEpisode() }
        [settingsButton, nextButton].forEach { $0.isHidden = true; view.addSubview($0) }

        buildTransport()
        buildLiveControls()
        buildErrors()

        backButton.fillOverride = UIColor(argb: 0xcc13263b)
        backButton.whiteText = true
        backButton.titleLabel?.numberOfLines = 1
        backButton.accessibilityLabel = "Back to menu"
        backButton.action = { [weak self] in self?.finish() }
        view.addSubview(backButton)

        NotificationCenter.default.addObserver(self, selector: #selector(sessionChanged),
                                               name: PlaybackSession.changed, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildTransport() {
        bottomBar.set([UIColor(argb: 0x00000000), UIColor(argb: 0xcc000000)], diagonal: false)
        bottomBar.isHidden = true
        view.addSubview(bottomBar)
        playPause.action = { [weak self] in self?.togglePlay() }
        for b in [rewind, forward] {
            b.plain = true
            b.whiteText = true
        }
        rewind.accessibilityLabel = "Back 10 seconds"
        forward.accessibilityLabel = "Forward 30 seconds"
        rewind.action = { [weak self] in self?.skip(-10_000) }
        forward.action = { [weak self] in self?.skip(30_000) }
        elapsed.textAlignment = .right
        elapsed.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        remaining.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        scrubber.minimumTrackTintColor = .white
        scrubber.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        scrubber.accessibilityLabel = "Playback position"
        scrubber.addTarget(self, action: #selector(scrubStarted), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubMoved), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let viewGroup1: [UIView] = [playPause, rewind, forward, elapsed, remaining, scrubber]
        viewGroup1.forEach { bottomBar.addSubview($0) }
    }

    private func buildLiveControls() {
        previousChannel = IconButton(label: "Previous channel", icon: "previous", size: 30) { [weak self] in self?.switchChannel(-1) }
        channelList = IconButton(label: "Channels", icon: "list", size: 26) { [weak self] in self?.showChannels() }
        nextChannel = IconButton(label: "Next channel", icon: "next", size: 30) { [weak self] in self?.switchChannel(1) }
        playbackButton = IconButton(label: "Playback settings", icon: "settings", size: 26) { [weak self] in
            self?.cancelHide()
            self?.hideLiveControls()
            self?.options.show()
        }
        lastChannelButton = IconButton(label: "Last channel", icon: "last-channel", size: 26) { [weak self] in
            if let last = self?.lastChannel { self?.openChannel(last) }
        }
        livePause = IconButton(label: "Pause", icon: "pause", size: 40) { [weak self] in
            self?.togglePlay()
            self?.resetLiveTimer()
        }
        // Top row: previous, play/pause, next. Lower row: last channel, channel list, settings.
        let transport = [previousChannel!, livePause!, nextChannel!]
        for (n, b) in transport.enumerated() {
            b.frame = CGRect(x: 12 + CGFloat(n) * 88, y: 0, width: 64, height: 64)
            liveBar.addSubview(b)
        }
        let lower = [lastChannelButton!, channelList!, playbackButton!]
        for (n, b) in lower.enumerated() {
            b.frame = CGRect(x: 20 + CGFloat(n) * 88, y: 72, width: 48, height: 48)
            liveBar.addSubview(b)
        }
        liveBar.isHidden = true
        view.addSubview(liveBar)
    }

    private func buildErrors() {
        errors.backgroundColor = Ui.bg
        errors.layer.cornerRadius = 2
        errors.layer.borderWidth = 1
        errors.layer.borderColor = Ui.cyan.cgColor
        errorLabel.textAlignment = .center
        retryButton.action = { [weak self] in self?.restartPlayback() }
        leaveButton.action = { [weak self] in self?.finish() }
        let viewGroup2: [UIView] = [errorLabel, retryButton, leaveButton]
        viewGroup2.forEach { errors.addSubview($0) }
        errors.isHidden = true
        view.addSubview(errors)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        host.frame = view.bounds
        touchLayer.frame = view.bounds
        if session.surface.superview === host { session.surface.frame = host.bounds }
        spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        backButton.frame = CGRect(x: safe.minX + 12, y: 8, width: 156, height: 48)
        titleBar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 64)
        let titleX = safe.minX + 180
        titleLabel.frame = CGRect(x: titleX, y: 14, width: max(0, safe.maxX - 12 - titleX), height: 36)

        var right = safe.maxX - 12
        if !nextButton.isHidden || item.kind == .EPISODE {
            nextButton.frame = CGRect(x: right - 180, y: 62, width: 180, height: 48)
            right -= 180 + Ui.gap
        }
        settingsButton.frame = CGRect(x: right - 138, y: 62, width: 138, height: 48)

        let barHeight: CGFloat = 84
        bottomBar.frame = CGRect(x: 0, y: view.bounds.height - barHeight, width: view.bounds.width, height: barHeight)
        let left = safe.minX + 12, usable = safe.width - 24
        let baseline: CGFloat = 26
        playPause.frame = CGRect(x: left, y: baseline, width: 52, height: 48)
        rewind.frame = CGRect(x: left + 56, y: baseline, width: 56, height: 48)
        forward.frame = CGRect(x: left + 116, y: baseline, width: 56, height: 48)
        elapsed.frame = CGRect(x: left + 176, y: baseline, width: 58, height: 48)
        remaining.frame = CGRect(x: left + usable - 58, y: baseline, width: 58, height: 48)
        scrubber.frame = CGRect(x: left + 242, y: baseline, width: max(40, usable - 242 - 66), height: 48)

        liveBar.frame = CGRect(x: view.bounds.midX - 132, y: view.bounds.midY - 60, width: 264, height: 120)

        let width = min(470, safe.width - 40)
        let textHeight = errorLabel.sizeThatFits(CGSize(width: width - 48, height: 400)).height
        let height = 18 + textHeight + 12 + 48 + Ui.gap + 48 + 18
        errors.frame = CGRect(x: view.bounds.midX - width / 2, y: max(4, view.bounds.midY - height / 2), width: width, height: height)
        errorLabel.frame = CGRect(x: 24, y: 18, width: width - 48, height: textHeight)
        retryButton.frame = CGRect(x: 24, y: errorLabel.frame.maxY + 12, width: width - 48, height: 48)
        leaveButton.frame = CGRect(x: 24, y: retryButton.frame.maxY + Ui.gap, width: width - 48, height: 48)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        createPlayer()
        if isLive {
            loadChannels()
            updateLiveControls()
            hideLiveControls()
        } else {
            showControls()
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancelHide()
        session.save()
    }

    // MARK: player

    private func createPlayer() {
        endHandled = false
        session.obtain(item, provider: provider, restart: restart)
        restart = false
        session.attach(to: host)
        view.setNeedsLayout()
        sessionChanged()
    }

    @objc private func sessionChanged() {
        guard isViewLoaded, !closed else { return }
        if let message = session.failure, session.same(item) {
            showPlaybackFailure(message)
        }
        if session.started || session.failure != nil || !session.active { spinner.stopAnimating() }
        else if errors.isHidden { spinner.startAnimating() }
        if session.ended && !endHandled && session.same(item) {
            endHandled = true
            if item.kind == .EPISODE {
                nextButton.isHidden = false
                view.setNeedsLayout()
            }
            if !isLive { showControls(autoHide: false) }
        }
        if isLive { updateLiveControls() }
        refresh()
    }

    private func togglePlay() {
        if session.ended && !isLive {
            restart = true
            createPlayer()
            return
        }
        if session.wantsPlay { session.pause() } else { session.play() }
        refresh()
    }

    private func skip(_ delta: Int64) {
        session.seek(to: session.positionMs + delta)
        resetHide()
        refresh()
    }

    private func time(_ ms: Int64) -> String {
        if ms < 0 { return "—" }
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", Int(h), Int(m), Int(s)) : String(format: "%d:%02d", Int(m), Int(s))
    }

    private func refresh() {
        let paused = !session.wantsPlay || session.ended
        if isLive {
            livePause?.setAction(paused ? "Play" : "Pause", paused ? "play" : "pause")
            return
        }
        playPause.setAction(paused ? "Play" : "Pause", paused ? "play" : "pause")
        let duration = session.durationMs, position = session.positionMs
        scrubber.isEnabled = duration > 0
        if !scrubbing {
            scrubber.value = duration > 0 ? Float(Double(position) / Double(duration)) : 0
            elapsed.text = time(position)
            remaining.text = duration > 0 ? time(duration) : "—"
        }
    }

    @objc private func scrubStarted() { scrubbing = true; cancelHide() }

    @objc private func scrubMoved() {
        let duration = session.durationMs
        if duration > 0 { elapsed.text = time(Int64(Double(scrubber.value) * Double(duration))) }
    }

    @objc private func scrubEnded() {
        let duration = session.durationMs
        if duration > 0 { session.seek(to: Int64(Double(scrubber.value) * Double(duration))) }
        scrubbing = false
        resetHide()
    }

    // MARK: film and episode controls

    @objc private func screenTapped() {
        if !errors.isHidden { return }
        if isLive {
            if liveBar.isHidden { showLiveControls() } else { hideLiveControls() }
        } else if controlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    private func showControls(autoHide: Bool = true) {
        guard !isLive else { return }
        controlsVisible = true
        bottomBar.isHidden = false
        titleBar.isHidden = false
        settingsButton.isHidden = false
        if item.kind == .EPISODE { nextButton.isHidden = false }
        view.setNeedsLayout()
        refresh()
        if autoHide { resetHide() } else { cancelHide() }
    }

    private func hideControls() {
        guard !isLive, errors.isHidden else { return }
        if session.ended { return }
        controlsVisible = false
        bottomBar.isHidden = true
        titleBar.isHidden = true
        settingsButton.isHidden = true
        nextButton.isHidden = true
    }

    private func cancelHide() { hideWork?.cancel(); hideWork = nil }

    private func resetHide() {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.presentedViewController == nil, !self.scrubbing else { return }
            if self.isLive { self.hideLiveControls() } else { self.hideControls() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    // MARK: live controls

    private func updateLiveControls() {
        guard isLive, livePause != nil else { return }
        lastChannelButton.isEnabled = lastChannel != nil
        previousChannel.isEnabled = channels.count > 1
        nextChannel.isEnabled = channels.count > 1
        channelList.setAction(channelsLoading ? "Loading channels…" : "Channels", "list")
    }

    private func showLiveControls() {
        guard isLive else { return }
        if !errors.isHidden {
            liveBar.isHidden = true
            titleBar.isHidden = true
            return
        }
        liveBar.isHidden = false
        titleBar.isHidden = false
        updateLiveControls()
        refresh()
        resetLiveTimer()
    }

    private func resetLiveTimer() { resetHide() }

    private func hideLiveControls() {
        guard isLive else { return }
        if !errors.isHidden || presentedViewController != nil { return }
        liveBar.isHidden = true
        titleBar.isHidden = true
    }

    private func loadChannels() {
        guard isLive, !channelsLoaded, !channelsLoading else { return }
        let category = live.category ?? item.category
        let query = live.query
        if let cached = live.channels {
            channels = LiveChannels.visible(cached, store, category, query, item)
            channelsLoaded = true
            updateLiveControls()
            return
        }
        channelsLoading = true
        updateLiveControls()
        channelGeneration += 1
        let ticket = channelGeneration
        let favourites = live.favourites, group = live.group, source = provider, current = item
        Task { [weak self] in
            do {
                let data: [MediaItem]
                if favourites { data = LocalStore.shared.favourites(group: group) }
                else if let source = source { data = try await source.catalogue(.LIVE, category) }
                else { data = Demo.catalogue(.LIVE) }
                guard let self = self, ticket == self.channelGeneration else { return }
                self.channels = LiveChannels.visible(data, self.store, category, query, current)
                self.channelsLoading = false
                self.channelsLoaded = true
                self.updateLiveControls()
            } catch {
                guard let self = self, ticket == self.channelGeneration else { return }
                self.channelsLoading = false
                self.updateLiveControls()
                Ui.toast("Channel list unavailable. Select Channels to retry; your stream is unaffected.")
            }
        }
    }

    private func switchChannel(_ delta: Int) {
        if channels.count < 2 { return }
        openChannel(LiveChannels.step(channels, item, delta))
    }

    private func openChannel(_ next: MediaItem) {
        if next.id == item.id { showLiveControls(); return }
        lastChannel = item
        item = next
        errors.isHidden = true
        titleLabel.text = titleText
        updateLiveControls()
        createPlayer()
        showLiveControls()
    }

    private func showChannels() {
        if !channelsLoaded {
            loadChannels()
            Ui.toast(channelsLoading ? "Loading channel list…" : "Channel list unavailable")
            return
        }
        cancelHide()
        let shown = channels
        let picker = PickerViewController()
        picker.heading = "Live channels"
        picker.rows = shown.map { $0.name }
        picker.selected = LiveChannels.index(shown, item)
        picker.searchable = true
        picker.searchPlaceholder = "Search channels"
        picker.buttons = [("Close", nil)]
        picker.onPick = { [weak self] n in self?.openChannel(shown[n]) }
        picker.onClose = { [weak self] in
            DispatchQueue.main.async { if self?.presentedViewController == nil { self?.showLiveControls() } }
        }
        present(picker, animated: true)
    }

    // MARK: next episode

    private func nextEpisode() {
        if nextLoading || item.kind != .EPISODE { return }
        nextLoading = true
        nextButton.isEnabled = false
        nextButton.title = "Finding next…"
        nextGeneration += 1
        let ticket = nextGeneration
        let current = item
        let series = MediaItem(kind: .SERIES, id: current.seriesId, name: "", category: current.category,
                               image: "", plot: "", ext: "", seriesId: "")
        if let cache = episodeCache { openNext(current, cache, ticket); return }
        guard let source = provider else { openNext(current, Demo.episodes(series), ticket); return }
        Task { [weak self] in
            do {
                let episodes = try await source.episodes(series)
                self?.openNext(current, episodes, ticket)
            } catch {
                guard let self = self, ticket == self.nextGeneration else { return }
                self.nextLoading = false
                self.nextButton.isEnabled = true
                self.nextButton.title = "Next episode ›"
                Ui.toast("Could not load the next episode. Try again.")
            }
        }
    }

    private func openNext(_ current: MediaItem, _ episodes: [Int: [MediaItem]], _ ticket: Int) {
        if ticket != nextGeneration { return }
        nextLoading = false
        episodeCache = episodes
        guard let next = Media.nextEpisode(episodes, current) else {
            nextButton.title = "No next episode"
            nextButton.isEnabled = false
            Ui.toast("No later episode is available in this series.")
            return
        }
        for (season, list) in episodes where list.contains(where: { $0.id == next.id }) {
            store.setSeason(next.seriesId, season)
        }
        session.save()
        item = next
        restart = false
        titleLabel.text = titleText
        errors.isHidden = true
        nextButton.isEnabled = true
        nextButton.title = "Next episode ›"
        createPlayer()
        showControls()
    }

    // MARK: failure and exit

    private func showPlaybackFailure(_ message: String) {
        if !errors.isHidden { return }
        spinner.stopAnimating()
        errorLabel.text = message + (isLive ? "\n\nLive stream format: " + store.liveFormat.uppercased() : "")
        errors.isHidden = false
        liveBar.isHidden = true
        view.setNeedsLayout()
    }

    private func restartPlayback() {
        errors.isHidden = true
        session.stop()
        createPlayer()
        if isLive { showLiveControls() } else { showControls() }
    }

    private func finish() {
        if closed { return }
        closed = true
        cancelHide()
        channelGeneration += 1
        nextGeneration += 1
        session.save()
        let result = item
        let callback = onFinish
        dismiss(animated: true) { callback?(result) }
    }
}
