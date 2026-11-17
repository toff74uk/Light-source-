import UIKit

/// The browser: section menu, categories, guide or posters, and the preview window.
final class MainViewController: BaseViewController, UITableViewDataSource, UITableViewDelegate, LiveGuideActions {
    private let store = LocalStore.shared
    private var provider: Provider?
    private var artwork = Artwork(allowHttp: false)
    private var startupError = ""

    // Chrome, rebuilt whenever the theme, profile or section list changes.
    private var chrome = UIView()
    private var logo = BrandView()
    private var heroArtwork = ArtView()
    private var searchButton = LMButton("Search", size: 11)
    private var programmeTitle = UILabel()
    private var programmeInfo = UILabel()
    private var programmeProgress = UIProgressView(progressViewStyle: .bar)
    private var programmePlot = UITextView()
    private var preview = LivePreviewView()
    private var menuScroll = UIScrollView()
    private var menuButtons: [LMButton] = []
    private var body = Pane()
    private var pageLabel = UILabel()
    private var pagePrevious = LMButton("‹ Previous")
    private var pageNow = LMButton("Now")
    private var pageNext = LMButton("Next ›")
    private var clock = UILabel()
    private var clockTimer: Timer?

    // Browsing state
    private var section = "Live TV"
    private var category = ""
    private var query = ""
    private var detailReturn = "Live TV"
    private var kind: Kind = .LIVE
    private var selected: MediaItem?
    private var catalogue: [MediaItem] = []
    private var categories: [MediaCategory] = []
    private var categoryCache: [Kind: [MediaCategory]] = [:]
    private var catalogueCache: [String: [MediaItem]] = [:]
    private var generation = 0
    private var returnIndex = 0
    private var detail = false
    private var accountPage = false
    private var navigationReady = false
    private var favouriteGroup = ""
    private var returnLiveId = ""
    private var liveLayout = false
    private var foreground = false
    private var browsingEdited = false
    private var profileRevision: Int64 = 0
    private var sectionsRevision: Int64 = 0
    private var headerExtra: CGFloat = 0
    private var menuGeometry = RowGeometry(viewport: 44, preferred: 44)

    // Parts of the current page
    private var categoryTable: UITableView?
    private var categoryGeometry = RowGeometry(viewport: 44, preferred: 44)
    private var resultsPane: Pane?
    private var grid: PosterGridView?
    private var liveGuide: LiveGuideView?
    private var detailResults: Pane?
    private var seasonButton: LMButton?
    private var formScroll: UIScrollView?
    private var statusLabel: UILabel?

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        do { try Profiles().recover() } catch { startupError = "Profile recovery needs attention. Open Settings → Profiles." }
        Ui.load()
        markThemeApplied()
        do {
            if let c = try store.account() { provider = Provider(c) }
        } catch {
            startupError = "Your saved login could not be opened. Re-enter it in Settings."
            PlaybackSession.shared.stop()
            store.logout()
        }
        artwork = Artwork(allowHttp: provider?.credentials.allowHttp ?? false)
        buildChrome()
        startLive()
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        centre.addObserver(self, selector: #selector(keyboardHidden), name: UIResponder.keyboardWillHideNotification, object: nil)
        centre.addObserver(self, selector: #selector(sessionChanged), name: PlaybackSession.changed, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var idleAllowed: Bool { return !preview.active }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        foreground = true
        Ui.load()
        if appliedTheme != Ui.themeKey || profileRevision != Profiles.revision() || sectionsRevision != MainSections.revision() {
            markThemeApplied()
            let target = MainSections.enabled(section) ? section : MainSections.first()
            buildChrome()
            browsingEdited = false
            navigate(target)
        } else if browsingEdited {
            browsingEdited = false
            if !detail && ["Live TV", "Films", "Series"].contains(section) { browse(kind) }
        } else if !detail && section == "Continue" {
            saved(true)
        } else {
            grid?.reload()
        }
        preview.resume(provider)
        liveGuide?.resume()
        if !startupError.isEmpty {
            let message = startupError
            startupError = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Ui.toast(message) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        foreground = false
        rememberBrowse()
        liveGuide?.pause()
    }

    @objc private func sessionChanged() {
        UIApplication.shared.isIdleTimerDisabled = PlaybackSession.shared.active && PlaybackSession.shared.wantsPlay
        IdleMonitor.shared.reset()
    }

    // MARK: chrome

    private func buildChrome() {
        profileRevision = Profiles.revision()
        sectionsRevision = MainSections.revision()
        clockTimer?.invalidate()
        chrome.removeFromSuperview()
        liveGuide?.close()
        liveGuide = nil
        grid = nil
        categoryTable = nil
        resultsPane = nil

        chrome = UIView(frame: view.bounds)
        chrome.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(chrome)

        logo = BrandView()
        heroArtwork = ArtView()
        heroArtwork.alignStart = true
        heroArtwork.bind("Light Media", nil)
        heroArtwork.isHidden = true

        searchButton = LMButton("Search", size: 11) { [weak self] in self?.askSearch() }
        programmeTitle = Ui.label("Light Media", 18, nil, lines: 2)
        programmeInfo = Ui.label("", 13, Ui.cyan, lines: 1)
        programmeProgress = UIProgressView(progressViewStyle: .bar)
        programmeProgress.progressTintColor = Ui.cyan
        programmeProgress.trackTintColor = UIColor.black.withAlphaComponent(0.15)
        programmePlot = UITextView()
        programmePlot.backgroundColor = .clear
        programmePlot.isEditable = false
        programmePlot.isSelectable = false
        programmePlot.font = Ui.font(13)
        programmePlot.textColor = Ui.text
        programmePlot.textContainerInset = .zero
        programmePlot.textContainer.lineFragmentPadding = 0
        programmePlot.showsVerticalScrollIndicator = true

        preview = LivePreviewView()
        preview.onOpen = { [weak self] in self?.openPreview() }

        menuScroll = UIScrollView()
        menuScroll.showsVerticalScrollIndicator = false
        menuScroll.bounces = false
        menuScroll.decelerationRate = .fast
        menuScroll.delegate = self
        menuButtons = []
        for id in MainSections.visible() {
            let b = LMButton(MainSections.title(id), size: 15) { [weak self] in self?.navigate(id) }
            b.alignLeft()
            b.accessibilityIdentifier = id
            menuScroll.addSubview(b)
            menuButtons.append(b)
        }

        body = Pane()
        pageLabel = Ui.label("", 11, Ui.muted, lines: 1)
        pageLabel.textAlignment = .right
        pagePrevious = LMButton("‹ Previous", size: 13) { [weak self] in
            if let guide = self?.liveGuide { guide.showEarlier() } else { self?.grid?.page(by: -1) }
        }
        pageNow = LMButton("Now", size: 13) { [weak self] in self?.liveGuide?.showNow() }
        pageNext = LMButton("Next ›", size: 13) { [weak self] in
            if let guide = self?.liveGuide { guide.showLater() } else { self?.grid?.page(by: 1) }
        }
        clock = Ui.label("", 12, Ui.muted, lines: 1)
        clock.textAlignment = .right
        clock.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        clock.accessibilityLabel = "Current time"
        updateClock()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.updateClock() }

        let viewGroup1: [UIView] = [logo, heroArtwork, searchButton, programmeTitle, programmeInfo, programmeProgress, programmePlot, preview,
         menuScroll, body, pageLabel, pagePrevious, pageNow, pageNext, clock]
        viewGroup1.forEach { chrome.addSubview($0) }
        view.setNeedsLayout()
    }

    private func updateClock() { clock.text = Epg.clock.string(from: Date()) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let r = pageRect
        let previewWidth = LivePreviewView.phoneWidth(screenWidth: r.width + 16, screenHeight: view.bounds.height)
        let previewHeight = (previewWidth * 9 / 16).rounded()
        let headerHeight = max(104, previewHeight + 8)
        headerExtra = max(0, headerHeight - 104)

        logo.frame = CGRect(x: r.minX, y: r.minY, width: 106, height: 94)
        let heroX = r.minX + 106 + 12
        var infoX = heroX
        if !heroArtwork.isHidden {
            heroArtwork.frame = CGRect(x: heroX, y: r.minY, width: 70, height: headerHeight - 6)
            infoX += 70 + 12
        }
        var infoRight = r.maxX
        if !preview.isHidden {
            preview.frame = CGRect(x: r.maxX - Ui.gap - previewWidth, y: r.minY, width: previewWidth, height: previewHeight)
            infoRight = preview.frame.minX - 16
        }
        let infoWidth = max(0, infoRight - infoX)
        var y = r.minY
        if !searchButton.isHidden {
            searchButton.frame = CGRect(x: infoX, y: y, width: 76, height: 28)
            y += 30
        }
        let titleHeight = min(44, programmeTitle.sizeThatFits(CGSize(width: infoWidth, height: 60)).height)
        programmeTitle.frame = CGRect(x: infoX, y: y, width: infoWidth, height: titleHeight)
        y += titleHeight
        programmeInfo.frame = CGRect(x: infoX, y: y, width: infoWidth, height: 18)
        y += 18
        if !programmeProgress.isHidden {
            programmeProgress.frame = CGRect(x: infoX, y: y + 1, width: infoWidth, height: 4)
            y += 5
        }
        programmePlot.frame = CGRect(x: infoX, y: y + 6, width: infoWidth, height: max(0, r.minY + headerHeight - y - 8))

        let rootTop = r.minY + headerHeight
        let footerTop = r.maxY - 40
        let navGap: CGFloat = liveLayout ? 46 : 30
        menuScroll.frame = CGRect(x: r.minX, y: rootTop + navGap, width: 94, height: max(0, footerTop - rootTop - navGap))
        menuGeometry = RowGeometry(viewport: menuScroll.bounds.height, preferred: Ui.row, extra: headerExtra)
        for (n, b) in menuButtons.enumerated() {
            b.frame = CGRect(x: 0, y: CGFloat(n) * menuGeometry.pitch, width: 94, height: menuGeometry.rowHeight)
        }
        menuScroll.contentSize = CGSize(width: 94, height: max(0, CGFloat(menuButtons.count) * menuGeometry.pitch - Ui.gap))

        body.frame = CGRect(x: heroX, y: rootTop, width: r.maxX - heroX, height: max(0, footerTop - rootTop))

        let nextX = r.maxX - 100
        pageNext.frame = CGRect(x: nextX, y: footerTop, width: 100, height: 24)
        clock.frame = CGRect(x: nextX, y: footerTop + 24, width: 100, height: 16)
        var x = nextX
        if !pageNow.isHidden {
            x -= 80
            pageNow.frame = CGRect(x: x, y: footerTop, width: 78, height: 24)
        }
        x -= 100
        pagePrevious.frame = CGRect(x: x, y: footerTop, width: 98, height: 24)
        pageLabel.frame = CGRect(x: heroX, y: footerTop, width: max(0, x - heroX - 8), height: 28)
    }

    // MARK: navigation

    private func rememberBrowse() {
        guard navigationReady, !detail else { return }
        if let grid = grid { returnIndex = grid.firstVisibleIndex }
        let key = store.navigationKey + section
        store.prefs.putString(key + ".category", category)
        store.prefs.putString(key + ".query", query)
        store.prefs.putInt(key + ".index", returnIndex)
    }

    private func startLive() { navigate(MainSections.first()) }

    private func navigate(_ target: String) {
        rememberBrowse()
        detail = false
        selected = nil
        let key = store.navigationKey + target
        category = store.prefs.string(key + ".category", "")
        query = store.prefs.string(key + ".query", "")
        returnIndex = store.prefs.int(key + ".index", 0)
        section = target
        navigationReady = true
        switch target {
        case "Live TV": browse(.LIVE)
        case "Films": browse(.MOVIE)
        case "Series": browse(.SERIES)
        case "Favourites": saved(false)
        case "Continue": saved(true)
        case "Downloads": downloads()
        case "My Music": mediaLibrary(.music)
        case "My Videos": mediaLibrary(.videos)
        default: settings()
        }
    }

    private func begin(_ title: String, _ caption: String) {
        liveLayout = false
        pageNow.isHidden = true
        pagePrevious.isHidden = true
        pageNext.isHidden = true
        pagePrevious.isEnabled = true
        pageNext.isEnabled = true
        pageLabel.text = ""
        accountPage = false
        searchButton.isHidden = true
        preview.isHidden = false
        heroArtwork.isHidden = true
        programmeTitle.text = title
        programmeInfo.text = caption
        programmePlot.text = ""
        programmePlot.textColor = Ui.text
        programmePlot.contentOffset = .zero
        programmeProgress.isHidden = true
        if foreground { preview.resume(provider) }
        generation += 1
        liveGuide?.close()
        liveGuide = nil
        categoryTable = nil
        resultsPane = nil
        detailResults = nil
        seasonButton = nil
        formScroll = nil
        statusLabel = nil
        grid = nil
        detail = false
        body.removeAllSubviews()
        body.onLayout = nil
        for b in menuButtons { b.isSelected = b.accessibilityIdentifier == section }
        view.setNeedsLayout()
    }

    private func setResults(_ content: UIView) {
        guard let pane = resultsPane ?? detailResults else { return }
        pane.removeAllSubviews()
        content.frame = pane.bounds
        pane.onLayout = { host in host.subviews.forEach { $0.frame = host.bounds } }
        pane.addSubview(content)
        pane.setNeedsLayout()
    }

    private func removeResults() {
        liveGuide?.close()
        liveGuide = nil
        grid = nil
        (resultsPane ?? detailResults)?.removeAllSubviews()
    }

    private func loading(_ text: String) { setResults(MessageView(text, size: 18)) }
    private func message(_ text: String, retry: (() -> Void)? = nil) { setResults(MessageView(text, retry: retry)) }

    // MARK: Live TV, Films and Series

    private func browse(_ newKind: Kind) {
        kind = newKind
        let demo = provider == nil
        begin(section, newKind == .LIVE
              ? (demo ? "Demo · Choose a category, then a channel" : "Choose a category, then a channel · Hold for options")
              : "Choose a category to browse")
        liveLayout = newKind == .LIVE
        browserLayout()
        searchButton.isHidden = false
        programmeProgress.isHidden = newKind != .LIVE
        programmeProgress.progress = 0
        programmePlot.text = newKind == .LIVE ? "Tap a channel to preview it. Tap it again for full screen."
                                             : "Tap a title for details · Hold for favourites and options"
        loading("Loading categories…")
        let ticket = generation
        guard let source = provider else { useCategories(Demo.categories()); return }
        if let cached = categoryCache[newKind] { useCategories(cached); return }
        Task { [weak self] in
            do {
                let data = try await source.categories(newKind)
                guard let self = self, ticket == self.generation else { return }
                self.categoryCache[newKind] = data
                self.useCategories(data)
            } catch {
                guard let self = self, ticket == self.generation else { return }
                self.message("Categories could not be loaded.") { [weak self] in self?.browse(newKind) }
            }
        }
    }

    private func browserLayout() {
        let live = kind == .LIVE
        let railLabel = Ui.label("CATEGORIES", 10, Ui.cyan, lines: 1)
        let table = UITableView(frame: .zero, style: .plain)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.showsVerticalScrollIndicator = false
        table.bounces = false
        table.decelerationRate = .fast
        table.register(PanelCell.self, forCellReuseIdentifier: "category")
        let titles = Ui.label("TITLES", 10, Ui.cyan, lines: 1)
        titles.isHidden = live
        let results = Pane()
        let viewGroup2: [UIView] = [railLabel, table, titles, results]
        viewGroup2.forEach { body.addSubview($0) }
        categoryTable = table
        resultsPane = results
        body.onLayout = { [weak self] pane in
            guard let self = self else { return }
            let rail: CGFloat = 136
            let labelHeight: CGFloat = live ? 46 : 30
            railLabel.frame = CGRect(x: 10, y: 0, width: rail - 22, height: labelHeight)
            let tableFrame = CGRect(x: 0, y: labelHeight, width: rail - 12, height: max(0, pane.bounds.height - labelHeight))
            if table.frame != tableFrame {
                table.frame = tableFrame
                self.categoryGeometry = RowGeometry(viewport: tableFrame.height, preferred: Ui.row, extra: self.headerExtra)
                table.rowHeight = self.categoryGeometry.pitch
                table.reloadData()
            }
            let top: CGFloat = live ? 0 : 30
            titles.frame = CGRect(x: rail, y: 0, width: pane.bounds.width - rail, height: 30)
            results.frame = CGRect(x: rail, y: top, width: max(0, pane.bounds.width - rail), height: max(0, pane.bounds.height - top))
        }
        body.setNeedsLayout()
        body.layoutIfNeeded()
    }

    private func useCategories(_ all: [MediaCategory]) {
        let hidden = store.hidden(kind)
        categories = store.ordered(kind, all).filter { $0.id.isEmpty || !hidden.contains($0.id) }
        if !categories.contains(where: { $0.id == category }) { category = "" }
        if provider != nil && category.isEmpty && categories.count > 1
            && !store.prefs.contains(store.navigationKey + section + ".category") {
            category = categories[1].id
        }
        categoryTable?.reloadData()
        if let at = categories.firstIndex(where: { $0.id == category }), let table = categoryTable, at < categories.count {
            let first = max(0, min(max(0, categories.count - categoryGeometry.visible), at / categoryGeometry.visible * categoryGeometry.visible))
            table.layoutIfNeeded()
            table.setContentOffset(CGPoint(x: 0, y: CGFloat(first) * categoryGeometry.pitch), animated: false)
        }
        if categories.count == 1 && all.count > 1 {
            removeResults()
            message("All categories are hidden. Enable some in Settings → Customise browsing.")
        } else {
            loadCatalogue()
        }
    }

    private func selectCategory(_ n: Int) {
        guard n >= 0, n < categories.count else { return }
        let changed = category != categories[n].id
        category = categories[n].id
        categoryTable?.reloadData()
        if changed {
            query = ""
            returnIndex = 0
            loadCatalogue()
        }
    }

    private func categoryName() -> String {
        return categories.first { $0.id == category }?.name ?? "All categories"
    }

    private func loadCatalogue() {
        catalogue = []
        generation += 1
        let ticket = generation
        removeResults()
        loading("Loading " + categoryName() + "…")
        guard let source = provider else {
            catalogue = Demo.catalogue(kind).filter { category.isEmpty || category == $0.category }
            filter()
            return
        }
        let key = kind.rawValue + ":" + category
        var cached = catalogueCache[key]
        if cached == nil, let everything = catalogueCache[kind.rawValue + ":"] {
            cached = everything.filter { category.isEmpty || category == $0.category }
        }
        if let cached = cached { catalogue = cached; filter(); return }
        let requestKind = kind, requestCategory = category
        Task { [weak self] in
            do {
                let data = try await source.catalogue(requestKind, requestCategory)
                guard let self = self, ticket == self.generation else { return }
                if self.catalogueCache.count > 5 { self.catalogueCache.removeAll() }
                self.catalogueCache[key] = data
                self.catalogue = data
                self.filter()
            } catch {
                guard let self = self, ticket == self.generation else { return }
                self.removeResults()
                self.message(safeError(error)) { [weak self] in self?.loadCatalogue() }
            }
        }
    }

    private func filter() {
        guard resultsPane != nil, !detail else { return }
        removeResults()
        let needle = query.lowercased()
        let hidden = store.hidden(kind), stations = store.hiddenStations(), hiddenTitles = store.hiddenTitles(kind)
        let filtered = store.orderedItems(kind, catalogue).filter { i in
            !hidden.contains(i.category) && !hiddenTitles.contains(i.id)
                && !(i.kind == .LIVE && stations.contains(i.id))
                && (needle.isEmpty || i.name.lowercased().contains(needle))
        }
        searchButton.title = query.isEmpty ? "Search" : "Search ●"
        if filtered.isEmpty {
            message("No titles found. Try another category or search.")
            return
        }
        if kind == .LIVE {
            let guide = LiveGuideView(provider: provider, channels: filtered)
            guide.actions = self
            guide.extra = headerExtra
            guide.onPageState = { [weak self] earlier, later in
                self?.pagePrevious.isEnabled = earlier
                self?.pageNext.isEnabled = later
            }
            liveGuide = guide
            setResults(guide)
            pagePrevious.isHidden = false
            pageNext.isHidden = false
            pageNow.isHidden = false
            pagePrevious.isEnabled = false
            pageNext.isEnabled = true
            view.setNeedsLayout()
            let remembered = returnLiveId.isEmpty ? store.prefs.string(store.navigationKey + "live.channel", "") : returnLiveId
            if !remembered.isEmpty {
                DispatchQueue.main.async { [weak guide] in guide?.scroll(to: remembered) }
            }
        } else {
            gridItems(filtered)
        }
    }

    private func askSearch() {
        guard resultsPane != nil, !detail else { return }
        Ui.input(self, title: "Search this category", text: query, placeholder: "Search this category", ok: "Search") { [weak self] text in
            self?.query = text
            self?.returnIndex = 0
            self?.filter()
        }
    }

    private func gridItems(_ items: [MediaItem]) {
        let view = PosterGridView(items: items, artwork: artwork)
        view.extra = headerExtra
        view.startIndex = max(0, min(returnIndex, items.count - 1))
        view.onTap = { [weak self] item, index in
            guard let self = self else { return }
            if !self.detail { self.returnIndex = index }
            if item.kind == .LIVE || item.kind == .EPISODE { self.play(item, restart: false) } else { self.details(item) }
        }
        view.onHold = { [weak self] item in self?.options(item) }
        let paged = !detail
        view.onPage = { [weak self] page, pages, count in
            if paged { self?.pageLabel.text = "Page \(page) of \(pages)  ·  \(count) titles   " }
        }
        grid = view
        setResults(view)
        if paged {
            pagePrevious.isHidden = false
            pageNext.isHidden = false
            self.view.setNeedsLayout()
        }
    }

    // MARK: Favourites and Continue

    private func saved(_ recent: Bool) {
        begin(recent ? "Continue watching" : "Favourites",
              recent ? "Pick up where you left off" : "Your saved channels, films and series")
        programmeTitle.text = section
        programmePlot.text = "Tap a title to open it · Hold for options"
        let label = Ui.label(recent ? "CONTINUE" : "GROUPS", 10, Ui.cyan, lines: 1)
        var railButtons: [LMButton] = []
        if !recent {
            if !favouriteGroup.isEmpty && !store.groupNames().contains(favouriteGroup) { favouriteGroup = "" }
            railButtons.append(LMButton(favouriteGroup.isEmpty ? "All favourites ▾" : favouriteGroup + " ▾") { [weak self] in
                guard let self = self else { return }
                let names = ["All favourites"] + self.store.groupNames()
                let current = self.favouriteGroup.isEmpty ? 0 : (names.firstIndex(of: self.favouriteGroup) ?? 0)
                Ui.choose(self, title: "Favourite group", items: names, selected: current) { [weak self] n in
                    self?.favouriteGroup = n == 0 ? "" : names[n]
                    self?.saved(false)
                }
            })
            railButtons.append(LMButton("Manage groups") { [weak self] in
                guard let self = self else { return }
                FavouriteGroups.manage(self) { [weak self] in self?.saved(false) }
            })
        }
        let titles = Ui.label("TITLES", 10, Ui.cyan, lines: 1)
        let results = Pane()
        body.addSubview(label)
        railButtons.forEach { body.addSubview($0) }
        body.addSubview(titles)
        body.addSubview(results)
        resultsPane = results
        body.onLayout = { pane in
            let rail: CGFloat = 106
            label.frame = CGRect(x: 10, y: 0, width: rail - 22, height: 30)
            var y: CGFloat = 30
            for b in railButtons {
                b.frame = CGRect(x: 0, y: y, width: rail - 12, height: 40)
                y += 44
            }
            titles.frame = CGRect(x: rail, y: 0, width: max(0, pane.bounds.width - rail), height: 30)
            results.frame = CGRect(x: rail, y: 30, width: max(0, pane.bounds.width - rail), height: max(0, pane.bounds.height - 30))
        }
        body.setNeedsLayout()
        body.layoutIfNeeded()
        let data = recent ? store.recent() : store.favourites(group: favouriteGroup)
        if data.isEmpty {
            message(recent ? "Play a film or episode and it will appear here."
                           : "Hold a channel or title and choose Favourite groups to add it here.")
        } else {
            gridItems(data)
        }
    }

    private func refreshSaved() {
        if section == "Continue" && !detail { saved(true) }
        else if section == "Favourites" && !detail { saved(false) }
        else { grid?.reload(); liveGuide?.reloadRows() }
    }

    // MARK: options

    private func options(_ item: MediaItem) {
        var opts = [store.favourite(item) ? "Remove favourite" : "Add favourite",
                    item.kind == .LIVE ? "Programme guide" : "Open details"]
        if item.kind == .LIVE { opts.append("Hide this station") }
        if item.kind == .MOVIE || item.kind == .EPISODE {
            opts.append(store.watched(item) ? "Mark unwatched" : "Mark watched")
            opts.append("Remove from Continue")
        }
        if item.kind == .MOVIE || item.kind == .EPISODE || item.kind == .AUDIO { opts.append("Download to iPhone") }
        opts.append("Favourite groups")
        Ui.choose(self, title: item.name, items: opts) { [weak self] n in
            guard let self = self else { return }
            switch opts[n] {
            case "Download to iPhone": self.download(item)
            case "Remove favourite", "Add favourite":
                self.store.toggle(item)
                self.refreshSaved()
            case "Programme guide", "Open details":
                self.details(item)
            case "Hide this station":
                var hidden = self.store.hiddenStations()
                hidden.insert(item.id)
                self.store.setHiddenStations(hidden)
                Ui.toast("Station hidden. Restore it in Customise browsing.")
                if self.section == "Live TV" && !self.detail { self.filter() } else { self.refreshSaved() }
            case "Mark unwatched", "Mark watched":
                self.store.setWatched(item, !self.store.watched(item))
                self.refreshSaved()
            case "Remove from Continue":
                self.store.removeContinue(item)
                self.refreshSaved()
            default:
                FavouriteGroups.choose(self, item) { [weak self] in self?.refreshSaved() }
            }
        }
    }

    // MARK: details

    private func details(_ item: MediaItem) {
        if !detail { rememberBrowse() }
        detailReturn = section
        selected = item
        let caption = item.kind == .SERIES ? "Choose a season, then an episode."
            : item.kind == .LIVE ? "Live television · Programme guide"
            : item.kind == .EPISODE ? "Episode details" : "Film details"
        begin(item.name, caption)
        detail = true
        let ticket = generation
        preview.isHidden = true
        heroArtwork.isHidden = false
        artwork.load(heroArtwork, item)
        let cachedPlot = store.synopsis(item)
        let initialPlot = cachedPlot ?? item.plot
        programmePlot.textColor = Ui.muted
        programmePlot.text = initialPlot.isEmpty ? "Synopsis unavailable from your provider." : initialPlot

        var buttons: [(LMButton, CGFloat)] = []
        buttons.append((LMButton("‹ Back") { [weak self] in self?.backToCatalogue() }, 95))
        if item.kind != .SERIES {
            let title = store.position(item) > 0 ? "Resume" : "▶ Watch now"
            buttons.append((LMButton(title) { [weak self] in self?.play(item, restart: false) }, 145))
        } else {
            let season = LMButton("Loading seasons…")
            seasonButton = season
            buttons.append((season, 0))
        }
        let fav = LMButton(store.favourite(item) ? "♥ Saved" : "♡ Favourite")
        fav.action = { [weak self, weak fav] in
            guard let self = self else { return }
            self.store.toggle(item)
            fav?.title = self.store.favourite(item) ? "♥ Saved" : "♡ Favourite"
        }
        buttons.append((fav, 143))
        if item.kind == .MOVIE || item.kind == .EPISODE || item.kind == .AUDIO {
            buttons.append((LMButton("↓ Download") { [weak self] in self?.download(item) }, 112))
        }
        let results = Pane()
        buttons.forEach { body.addSubview($0.0) }
        body.addSubview(results)
        detailResults = results
        body.onLayout = { pane in
            let gaps = CGFloat(buttons.count - 1) * Ui.gap
            let widths = buttons.reduce(CGFloat(0)) { $0 + $1.1 }
            let scale = min(1, max(0, pane.bounds.width - gaps) / max(1, widths))
            let fixed = widths * scale + gaps
            let flexible = max(60, pane.bounds.width - fixed)
            var x: CGFloat = 0
            for (button, width) in buttons {
                let w = width == 0 ? flexible : width * scale
                button.frame = CGRect(x: x, y: 0, width: w, height: Ui.row)
                x += w + Ui.gap
            }
            results.frame = CGRect(x: 0, y: Ui.row + Ui.gap, width: pane.bounds.width,
                                   height: max(0, pane.bounds.height - Ui.row - Ui.gap))
        }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        body.layoutIfNeeded()

        if !item.sourceURL.isEmpty || !item.downloadID.isEmpty {
            programmePlot.text = item.plot.isEmpty ? "Your media · play or download on this iPhone." : item.plot
            return
        }

        if item.kind == .SERIES {
            loading("Loading episodes…")
            guard let source = provider else { showEpisodes(Demo.episodes(item)); return }
            Task { [weak self] in
                do {
                    let info = try await source.seriesInfo(item)
                    let episodes = Media.parseEpisodes(info, item)
                    let metadata = info["info"] as? [String: Any]
                    let description = metadata.map { Media.clean($0, "plot") } ?? item.plot
                    guard let self = self, ticket == self.generation else { return }
                    self.store.setSynopsis(item, description)
                    if !description.isEmpty { self.programmePlot.text = description }
                    self.showEpisodes(episodes)
                } catch {
                    guard let self = self, ticket == self.generation else { return }
                    self.seasonButton?.title = "No seasons loaded"
                    self.message(safeError(error)) { [weak self] in self?.details(item) }
                }
            }
        } else if item.kind == .LIVE {
            let guide = UITextView()
            guide.backgroundColor = .clear
            guide.isEditable = false
            guide.isSelectable = false
            guide.font = Ui.font(15)
            guide.textColor = Ui.text
            guide.textContainerInset = .zero
            guide.text = provider == nil
                ? "Demo schedule\n\nNow   RG motion test\nNext   RG motion test\n\nConnect your provider for actual programme information."
                : "Loading programme information…"
            setResults(guide)
            if let source = provider {
                Task { [weak self, weak guide] in
                    var text = "Programme information unavailable. You can still try watching this channel."
                    if let loaded = try? await source.guide(item) { text = loaded }
                    guard let self = self, ticket == self.generation else { return }
                    guide?.text = text
                }
            }
        } else {
            let holder = Pane()
            let restart = LMButton("Play from beginning") { [weak self] in self?.play(item, restart: true) }
            holder.addSubview(restart)
            holder.onLayout = { _ in restart.frame = CGRect(x: 0, y: 0, width: 220, height: Ui.row) }
            setResults(holder)
            if let source = provider, item.kind == .MOVIE, cachedPlot == nil, item.plot.isEmpty {
                Task { [weak self] in
                    guard let text = try? await source.moviePlot(item) else { return }
                    guard let self = self, ticket == self.generation else { return }
                    self.store.setSynopsis(item, text)
                    self.programmePlot.text = text.isEmpty ? "Synopsis unavailable from your provider." : text
                }
            }
        }
    }

    private func showEpisodes(_ seasons: [Int: [MediaItem]]) {
        guard let button = seasonButton, let series = selected else { return }
        let numbers = seasons.keys.sorted()
        guard let firstNumber = numbers.first else {
            button.title = "No seasons"
            message("Your provider returned no episodes for this series.")
            return
        }
        let remembered = store.season(series)
        let first = seasons[remembered] != nil ? remembered : firstNumber
        button.title = "Season \(first)  ▾"
        returnIndex = 0
        gridItems(seasons[first] ?? [])
        button.action = { [weak self, weak button] in
            guard let self = self else { return }
            let names = numbers.map { "Season \($0)" }
            Ui.choose(self, title: "Select season", items: names) { [weak self] n in
                guard let self = self else { return }
                self.store.setSeason(series.id, numbers[n])
                button?.title = names[n] + "  ▾"
                self.returnIndex = 0
                self.gridItems(seasons[numbers[n]] ?? [])
            }
        }
    }

    private func backToCatalogue() {
        detail = false
        selected = nil
        section = detailReturn
        let key = store.navigationKey + section
        returnIndex = store.prefs.int(key + ".index", 0)
        switch section {
        case "Favourites": saved(false)
        case "Continue": saved(true)
        default: browse(kind)
        }
    }

    // MARK: guide actions

    func guidePlay(_ item: MediaItem) {
        if preview.same(item) && preview.active { play(item, restart: false) } else { preview.select(item, provider) }
    }

    func guideOptions(_ item: MediaItem) { options(item) }

    func guideHighlight(_ item: MediaItem, _ programme: Programme?, _ status: String) {
        store.prefs.putString(store.navigationKey + "live.channel", item.id)
        returnLiveId = item.id
        programmeTitle.text = programme?.title ?? item.name
        programmeInfo.text = item.name + "  ·  " + (programme?.times() ?? status)
        if let p = programme {
            programmePlot.text = p.description.isEmpty ? "No synopsis supplied. Tap the channel to preview it." : p.description
            let now = nowMillis()
            programmeProgress.progress = Float(max(0, min(1, Double(now - p.start) / Double(max(1, p.end - p.start)))))
        } else {
            programmePlot.text = "Programme information unavailable. Tapping the channel still previews it."
            programmeProgress.progress = 0
        }
        view.setNeedsLayout()
    }

    // MARK: playback

    private func openPreview() {
        if let item = preview.item() { play(item, restart: false) }
    }

    private func play(_ item: MediaItem, restart: Bool) {
        if item.kind == .SERIES { details(item); return }
        var context = LiveContext()
        if item.kind == .LIVE {
            let favourites = section == "Favourites"
            let source = favourites ? store.favourites(group: favouriteGroup) : store.orderedStations(catalogue)
            context.favourites = favourites
            context.group = favouriteGroup
            context.category = favourites ? "" : category
            context.query = favourites ? "" : query
            context.channels = LiveChannels.visible(source, store, context.category ?? "", context.query, item)
            returnLiveId = item.id
        }
        let source = item.sourceURL.isEmpty && item.downloadID.isEmpty ? provider : nil
        let player = PlayerViewController(item: item, provider: source, restart: restart, live: context)
        player.onFinish = { [weak self] returned in self?.returned(from: returned) }
        present(player, animated: true)
    }

    private func returned(from item: MediaItem) {
        if item.kind == .LIVE {
            returnLiveId = item.id
            store.prefs.putString(store.navigationKey + "live.channel", item.id)
        }
        preview.remember(item)
        preview.resume(provider)
        if detail, item.kind == .LIVE { backToCatalogue() }
        else if let guide = liveGuide, item.kind == .LIVE { guide.scroll(to: item.id) }
        else if section == "Continue" && !detail { saved(true) }
        else { grid?.reload() }
    }

    private func restartVideo() {
        let current = PlaybackSession.shared.item
        PlaybackSession.shared.stop()
        if let current = current { preview.select(current, provider) }
        Ui.toast(current == nil ? "Player cleared · choose a channel" : "Playback restarted")
    }

    // MARK: settings

    private func download(_ item: MediaItem) {
        do {
            try DownloadManager.shared.enqueue(item, provider: provider)
            Ui.toast("Added to Downloads · open Downloads to view progress")
        } catch { Ui.message(self, title: "Download", message: error.localizedDescription) }
    }

    private func downloads() {
        begin("Downloads", "Your offline films, episodes and music")
        let list = DownloadsView(host: self) { [weak self] item in self?.play(item, restart: false) }
        body.addSubview(list)
        body.onLayout = { pane in list.frame = pane.bounds }
    }

    private func mediaLibrary(_ type: LibraryMediaType) {
        begin(type == .music ? "My Music" : "My Videos", "Your UPnP media library")
        let list = UPnPBrowserView(host: self, type: type, onSettings: { [weak self] in
            self?.open(MediaServersViewController())
        }, onPlay: { [weak self] item in self?.play(item, restart: false) })
        body.addSubview(list)
        body.onLayout = { pane in list.frame = pane.bounds }
    }

    private func menuHeader(_ title: String, _ description: String) {
        begin(title, description)
        programmePlot.text = "Choose a tile to open it."
    }

    private func settings() {
        menuHeader("Settings", "Light Media · v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.12"))
        let tiles = TileBoardView(heading: "SETTINGS")
        tiles.extra = headerExtra
        tiles.rail("All settings", selected: true) {}
        tiles.rail("Account", selected: false) { [weak self] in self?.accountSettings() }
        tiles.add("Appearance", glyph: "appearance") { [weak self] in self?.open(AppearanceViewController()) }
        tiles.add("Profiles", glyph: "profile") { [weak self] in self?.open(ProfilesViewController()) }
        tiles.add("Customise browsing", glyph: "search") { [weak self] in
            self?.browsingEdited = true
            self?.open(CustomiseViewController())
        }
        tiles.add("Screensaver", glyph: "moon") { [weak self] in self?.open(ScreensaverSettingsViewController()) }
        tiles.add("Account", glyph: "profile") { [weak self] in self?.accountSettings() }
        tiles.add("Add server (UPnP)", glyph: "folder") { [weak self] in self?.open(MediaServersViewController()) }
        tiles.add("Watch history", glyph: "trash") { [weak self] in
            guard let self = self else { return }
            Ui.confirm(self, title: "Clear watch history?", message: "Remove saved playback positions for this account?", ok: "Clear") { [weak self] in
                self?.store.clearHistory()
                Ui.toast("Watch history cleared")
            }
        }
        body.addSubview(tiles)
        body.onLayout = { pane in tiles.frame = pane.bounds }
        body.setNeedsLayout()
    }

    private func accountSettings() {
        begin("Account", "Your provider connection")
        accountPage = true
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        let form = UIView()
        form.backgroundColor = Ui.panel
        form.layer.cornerRadius = 2
        scroll.addSubview(form)
        body.addSubview(scroll)
        formScroll = scroll

        var rows: [(UIView, CGFloat)] = []
        func add(_ view: UIView, _ height: CGFloat) { form.addSubview(view); rows.append((view, height)) }
        func hint(_ text: String) -> UILabel { return Ui.label(text, 12, Ui.muted, lines: 0) }

        add(LMButton("‹ Back to Settings") { [weak self] in self?.navigate("Settings") }, 38)
        var host = ""
        if let p = provider { host = URLComponents(string: p.credentials.server)?.host ?? "" }
        add(Ui.label(provider == nil ? "You are using the demo catalogue." : "Connected to " + host, 16, nil, lines: 1), 28)
        add(LMButton("Restart playback") { [weak self] in self?.restartVideo() }, 42)

        if provider != nil {
            let format = LMButton("Live stream format: " + store.liveFormat.uppercased())
            format.action = { [weak self, weak format] in
                guard let self = self else { return }
                self.store.liveFormat = self.store.liveFormat == "m3u8" ? "ts" : "m3u8"
                format?.title = "Live stream format: " + self.store.liveFormat.uppercased()
                if PlaybackSession.shared.item?.kind == .LIVE { self.restartVideo() }
            }
            add(format, 42)
            add(hint("If a live channel will not play, try the other format."), 20)
            add(LMButton("Refresh catalogues") { [weak self] in self?.refreshCatalogues() }, 42)
            add(LMButton("Sign out and use demo") { [weak self] in
                guard let self = self else { return }
                Ui.confirm(self, title: "Sign out?",
                           message: "Remove this device's saved login? Your favourites stay on this device for your next login.",
                           ok: "Sign out") { [weak self] in self?.signOut() }
            }, 42)
        } else {
            let server = Ui.field("https://your-provider:port")
            server.keyboardType = .URL
            server.accessibilityLabel = "Server URL"
            let user = Ui.field("Provider username")
            user.accessibilityLabel = "Username"
            let password = Ui.field("Provider password", secure: true)
            password.accessibilityLabel = "Password"
            for f in [server, user, password] { f.addTarget(self, action: #selector(fieldDone(_:)), for: .editingDidEndOnExit) }
            let http = UISwitch()
            let httpLabel = hint("Allow HTTP if required by my provider (unencrypted)")
            let httpRow = Pane()
            httpRow.addSubview(http)
            httpRow.addSubview(httpLabel)
            httpRow.onLayout = { pane in
                http.frame.origin = CGPoint(x: 0, y: (pane.bounds.height - http.bounds.height) / 2)
                httpLabel.frame = CGRect(x: http.frame.maxX + 10, y: 0, width: max(0, pane.bounds.width - http.frame.maxX - 10), height: pane.bounds.height)
            }
            let status = hint("Your login stays on this device and is sent only to the server you enter.")
            statusLabel = status
            let connect = LMButton("Connect provider")
            connect.action = { [weak self, weak connect] in
                self?.view.endEditing(true)
                self?.connect(server.text ?? "", user.text ?? "", password.text ?? "", http.isOn, connect)
            }
            add(hint("Server URL"), 16); add(server, 40)
            add(hint("Username"), 16); add(user, 40)
            add(hint("Password"), 16); add(password, 40)
            add(httpRow, 36)
            add(status, 34)
            add(connect, 43)
        }

        body.onLayout = { pane in
            scroll.frame = pane.bounds
            let width = pane.bounds.width - 6
            var y: CGFloat = 14
            for (view, height) in rows {
                view.frame = CGRect(x: 14, y: y, width: max(0, width - 28), height: height)
                y += height + 6
            }
            form.frame = CGRect(x: 0, y: 0, width: width, height: y + 8)
            scroll.contentSize = CGSize(width: width, height: y + 12)
        }
        body.setNeedsLayout()
    }

    @objc private func fieldDone(_ field: UITextField) { field.resignFirstResponder() }

    private func connect(_ server: String, _ user: String, _ password: String, _ http: Bool, _ button: LMButton?) {
        let credentials: Credentials
        do {
            credentials = try Credentials(server: server, user: user, password: password, allowHttp: http)
        } catch {
            statusLabel?.text = error.localizedDescription
            return
        }
        button?.isEnabled = false
        statusLabel?.text = "Checking your account…"
        let ticket = generation
        let candidate = Provider(credentials)
        Task { [weak self] in
            do {
                try await candidate.authenticate()
                guard let self = self, ticket == self.generation else { return }
                do {
                    PlaybackSession.shared.stop()
                    try self.store.saveAccount(credentials)
                    self.provider = candidate
                    self.artwork.close()
                    self.artwork = Artwork(allowHttp: credentials.allowHttp)
                    self.catalogueCache.removeAll()
                    self.categoryCache.removeAll()
                    self.buildChrome()
                    self.startLive()
                    Ui.toast("Provider connected")
                } catch {
                    button?.isEnabled = true
                    self.statusLabel?.text = "The login worked, but it could not be saved securely on this device."
                }
            } catch {
                guard let self = self, ticket == self.generation else { return }
                button?.isEnabled = true
                self.statusLabel?.text = safeError(error)
            }
        }
    }

    private func signOut() {
        generation += 1
        PlaybackSession.shared.stop()
        store.logout()
        provider = nil
        catalogueCache.removeAll()
        categoryCache.removeAll()
        artwork.close()
        artwork = Artwork(allowHttp: false)
        buildChrome()
        startLive()
    }

    private func refreshCatalogues() {
        guard let source = provider else { return }
        let progress = UIAlertController(title: "Refresh catalogues", message: "Loading Live TV…", preferredStyle: .alert)
        present(progress, animated: true)
        Task { [weak self] in
            var cats: [Kind: [MediaCategory]] = [:]
            var lists: [String: [MediaItem]] = [:]
            var failure: Error?
            do {
                for k in [Kind.LIVE, Kind.MOVIE, Kind.SERIES] {
                    progress.message = "Loading " + (k == .LIVE ? "Live TV" : k == .MOVIE ? "Films" : "Series") + "…"
                    cats[k] = try await source.categories(k)
                    lists[k.rawValue + ":"] = try await source.catalogue(k, "")
                }
            } catch {
                failure = error
            }
            progress.dismiss(animated: true) { [weak self] in
                guard let self = self else { return }
                if let failure = failure {
                    Ui.message(self, title: "Refresh incomplete",
                               message: safeError(failure) + " Your previous catalogue is still available.")
                    return
                }
                guard self.provider === source else { return }
                self.categoryCache = cats
                self.catalogueCache = lists
                Ui.toast("Live TV, Films and Series refreshed.")
            }
        }
    }

    // MARK: keyboard

    @objc private func keyboardChanged(_ note: Notification) {
        guard let scroll = formScroll, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = scroll.convert(frame, from: nil)
        let overlap = max(0, scroll.bounds.maxY - local.minY)
        scroll.contentInset.bottom = overlap
        scroll.verticalScrollIndicatorInsets.bottom = overlap
        if let field = scroll.subviews.first?.subviews.first(where: { $0.isFirstResponder }) {
            scroll.scrollRectToVisible(field.convert(field.bounds, to: scroll).insetBy(dx: 0, dy: -10), animated: true)
        }
    }

    @objc private func keyboardHidden() {
        formScroll?.contentInset.bottom = 0
        formScroll?.verticalScrollIndicatorInsets.bottom = 0
    }

    // MARK: category list and menu scrolling

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return categories.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "category", for: indexPath)
        guard let row = cell as? PanelCell else { return cell }
        let item = categories[indexPath.row]
        row.title.text = item.name
        row.activated = item.id == category
        return row
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectCategory(indexPath.row)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if scrollView === menuScroll {
            targetContentOffset.pointee.y = menuGeometry.snapped(targetContentOffset.pointee.y, rows: menuButtons.count)
        } else if scrollView === categoryTable {
            targetContentOffset.pointee.y = categoryGeometry.snapped(targetContentOffset.pointee.y, rows: categories.count)
        }
    }
}

// MARK: - Favourite groups

/// Group editing; membership adds a favourite without losing existing ones.
enum FavouriteGroups {
    static func choose(_ host: UIViewController, _ item: MediaItem, changed: @escaping () -> Void) {
        let store = LocalStore.shared
        let names = store.groupNames()
        var chosen = store.groups(of: item)
        let picker = PickerViewController()
        picker.heading = "Groups · " + item.name
        picker.rows = names
        picker.checked = Set(names.indices.filter { chosen.contains(names[$0]) })
        picker.onToggle = { n, on in
            if on { chosen.insert(names[n]) } else { chosen.remove(names[n]) }
        }
        let create: () -> Void = { [weak host] in
            guard let host = host else { return }
            name(host, old: nil) { [weak host] in
                if let host = host { choose(host, item, changed: changed) }
            }
        }
        let save: () -> Void = {
            store.setGroups(item, chosen)
            changed()
        }
        picker.buttons = [("New group", create), ("Cancel", nil), ("Save", save)]
        host.present(picker, animated: true)
    }

    static func manage(_ host: UIViewController, changed: @escaping () -> Void) {
        let store = LocalStore.shared
        let names = store.groupNames()
        Ui.choose(host, title: "Favourite groups", items: ["Create group"] + names, cancel: "Close") { [weak host] n in
            guard let host = host else { return }
            if n == 0 { name(host, old: nil, changed: changed); return }
            let group = names[n - 1]
            Ui.choose(host, title: group, items: ["Rename", "Delete group"]) { [weak host] action in
                guard let host = host else { return }
                if action == 0 { name(host, old: group, changed: changed); return }
                Ui.confirm(host, title: "Delete " + group + "?", message: "Your favourites stay saved in All favourites.", ok: "Delete") {
                    store.deleteGroup(group)
                    changed()
                }
            }
        }
    }

    private static func name(_ host: UIViewController, old: String?, changed: @escaping () -> Void) {
        Ui.input(host, title: old == nil ? "New favourite group" : "Rename group", text: old ?? "", placeholder: "Group name") { [weak host] text in
            let store = LocalStore.shared
            let ok = old == nil ? store.createGroup(text) : store.renameGroup(old ?? "", text)
            if ok { changed() } else if let host = host {
                Ui.message(host, title: "Group not saved", message: "Use a unique name, 1–32 characters. Maximum 20 groups.")
            }
        }
    }
}
