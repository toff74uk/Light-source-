import UIKit

// MARK: - Appearance

final class AppearanceViewController: PageViewController {
    static let colours: [UInt32] = [Theme.blue, Theme.pink, Theme.yellow, 0xffef5350, 0xffec407a, 0xffab47bc, 0xff7e57c2,
        0xff5c6bc0, 0xff42a5f5, 0xff29b6f6, 0xff26c6da, 0xff26a69a, 0xff66bb6a, 0xff9ccc65, 0xffd4e157, 0xffffee58,
        0xffffca28, 0xffffa726, 0xffff7043, 0xff8d6e63, 0xff78909c, 0xffb0bec5, 0xffeeeeee, 0xff555555, 0xfff8bbd0,
        0xffe1bee7, 0xffd1c4e9, 0xffbbdefb, 0xffb2ebf2, 0xffb2dfdb, 0xffc8e6c9, 0xffffe0b2]
    static let names = ["Default Blue", "Retro Pink", "Yellow", "Red", "Rose", "Purple", "Violet", "Indigo", "Sky blue",
        "Azure", "Cyan", "Teal", "Green", "Lime", "Chartreuse", "Lemon", "Gold", "Orange", "Coral", "Cocoa", "Slate",
        "Silver", "Pearl", "Charcoal", "Soft rose", "Lavender", "Lilac", "Ice blue", "Ice cyan", "Mint", "Sage", "Peach"]

    private var hue = 0.0, saturationValue = 0.0, brightnessValue = 1.0
    private var black = false
    private let scroll = UIScrollView()
    private var presets: [LMButton] = []
    private let colourLabel = Ui.label("", 13, nil, lines: 1)
    private var swatches: [UIButton] = []
    private let strengthLabel = Ui.label("Colour strength", 12, nil, lines: 1)
    private let brightnessLabel = Ui.label("Brightness", 12, nil, lines: 1)
    private let saturation = UISlider()
    private let brightness = UISlider()
    private let whiteButton = LMButton("White text")
    private let blackButton = LMButton("Black text")
    private let sample = GradientView()
    private let sampleTitle = Ui.label("Light Media · Live preview", 21, nil, lines: 1)
    private let sampleHint = Ui.label("Your chosen background, panels and text", 13, nil, lines: 1)
    private let sampleMenu = UILabel()
    private let sampleSelected = UILabel()
    private let sampleBrand = BrandView()
    private let applyButton = LMButton("Apply")
    private let cancelButton = LMButton("Cancel")

    override var pageTitle: String { return "Appearance" }
    override var pageSubtitle: String { return "Choose your background and text. Only Apply changes the app." }
    override var showsBack: Bool { return false }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = Theme.read()
        setColour(theme.base)
        black = theme.black

        content.addSubview(scroll)
        for (n, name) in ["Default Blue", "Retro Pink", "Yellow"].enumerated() {
            let colour = [Theme.blue, Theme.pink, Theme.yellow][n]
            let b = LMButton(name, size: 12) { [weak self] in self?.setColour(colour); self?.sync() }
            presets.append(b)
            scroll.addSubview(b)
        }
        scroll.addSubview(colourLabel)
        for (n, colour) in AppearanceViewController.colours.enumerated() {
            let b = UIButton(type: .custom)
            b.backgroundColor = UIColor(argb: colour)
            b.layer.cornerRadius = 2
            b.tag = n
            b.accessibilityLabel = AppearanceViewController.names[n]
            b.addTarget(self, action: #selector(swatchTapped(_:)), for: .touchUpInside)
            swatches.append(b)
            scroll.addSubview(b)
        }
        saturation.minimumValue = 0
        saturation.maximumValue = 100
        saturation.accessibilityLabel = "Colour strength"
        brightness.minimumValue = 10
        brightness.maximumValue = 100
        brightness.accessibilityLabel = "Brightness"
        for s in [saturation, brightness] {
            s.minimumTrackTintColor = Ui.text
            s.addTarget(self, action: #selector(sliderMoved(_:)), for: .valueChanged)
            scroll.addSubview(s)
        }
        whiteButton.action = { [weak self] in self?.black = false; self?.sync() }
        blackButton.action = { [weak self] in self?.black = true; self?.sync() }
        let viewGroup1: [UIView] = [strengthLabel, brightnessLabel, whiteButton, blackButton]
        viewGroup1.forEach { scroll.addSubview($0) }

        sample.layer.cornerRadius = 2
        sample.clipsToBounds = true
        content.addSubview(sample)
        for l in [sampleMenu, sampleSelected] {
            l.font = Ui.font(14)
            l.textAlignment = .center
            l.layer.cornerRadius = 2
            l.layer.masksToBounds = true
        }
        sampleMenu.text = "Films and series"
        sampleSelected.text = "Selected tile"
        let viewGroup2: [UIView] = [sampleTitle, sampleHint, sampleMenu, sampleSelected, sampleBrand]
        viewGroup2.forEach { sample.addSubview($0) }

        applyButton.action = { [weak self] in
            self?.draft().save()
            self?.close()
        }
        cancelButton.action = { [weak self] in self?.close() }
        content.addSubview(applyButton)
        content.addSubview(cancelButton)

        content.onLayout = { [weak self] pane in self?.layout(pane) }
        sync()
    }

    private func layout(_ pane: Pane) {
        let actionsTop = pane.bounds.height - 44
        let left = min(392, (pane.bounds.width * 0.52).rounded())
        scroll.frame = CGRect(x: 0, y: 0, width: left, height: max(0, actionsTop - 10))
        var y: CGFloat = 0
        let each = (left - CGFloat(presets.count) * Ui.gap) / CGFloat(presets.count)
        for (n, b) in presets.enumerated() { b.frame = CGRect(x: CGFloat(n) * (each + Ui.gap), y: y, width: each, height: 40) }
        y += 44
        colourLabel.frame = CGRect(x: 0, y: y, width: left, height: 22)
        y += 24
        let cell = (left - 8) / 8
        for (n, b) in swatches.enumerated() {
            b.frame = CGRect(x: CGFloat(n % 8) * cell + 2, y: y + CGFloat(n / 8) * 34 + 2, width: cell - 6, height: 30)
        }
        y += 4 * 34 + 6
        strengthLabel.frame = CGRect(x: 0, y: y, width: left, height: 16); y += 16
        saturation.frame = CGRect(x: 4, y: y, width: left - 12, height: 34); y += 36
        brightnessLabel.frame = CGRect(x: 0, y: y, width: left, height: 16); y += 16
        brightness.frame = CGRect(x: 4, y: y, width: left - 12, height: 34); y += 38
        let half = (left - Ui.gap * 2) / 2
        whiteButton.frame = CGRect(x: 0, y: y, width: half, height: 40)
        blackButton.frame = CGRect(x: half + Ui.gap, y: y, width: half, height: 40)
        y += 44
        scroll.contentSize = CGSize(width: left, height: y)

        sample.frame = CGRect(x: left + 20, y: 0, width: max(0, pane.bounds.width - left - 20), height: max(0, actionsTop - 10))
        let w = sample.bounds.width - 36
        sampleTitle.frame = CGRect(x: 18, y: 14, width: w, height: 28)
        sampleHint.frame = CGRect(x: 18, y: 42, width: w, height: 18)
        sampleMenu.frame = CGRect(x: 18, y: 70, width: w, height: 40)
        sampleSelected.frame = CGRect(x: 18, y: 118, width: w, height: 40)
        sampleBrand.frame = CGRect(x: 18, y: 166, width: w, height: max(0, sample.bounds.height - 176))

        let button = (pane.bounds.width - 8) / 2
        applyButton.frame = CGRect(x: 0, y: actionsTop, width: button, height: 44)
        cancelButton.frame = CGRect(x: button + 8, y: actionsTop, width: button, height: 44)
    }

    private func setColour(_ colour: UInt32) {
        let c = Theme.hsv(colour)
        hue = c.h
        saturationValue = c.s
        brightnessValue = c.v
    }

    private func draft() -> Theme {
        return Theme(base: Theme.colour(h: hue, s: saturationValue, v: brightnessValue), black: black)
    }

    @objc private func swatchTapped(_ sender: UIButton) {
        setColour(AppearanceViewController.colours[sender.tag])
        sync()
    }

    @objc private func sliderMoved(_ sender: UISlider) {
        if sender === saturation { saturationValue = Double(sender.value) / 100 } else { brightnessValue = Double(sender.value) / 100 }
        sync(sliders: false)
    }

    private func sync(sliders: Bool = true) {
        if sliders {
            saturation.value = Float((saturationValue * 100).rounded())
            brightness.value = Float((brightnessValue * 100).rounded())
        }
        let t = draft()
        colourLabel.text = String(format: "#%06X", Int(t.base & 0xffffff))
        sample.set([UIColor(argb: t.base), UIColor(argb: t.end)])
        let text = UIColor(argb: t.text)
        [sampleTitle, sampleHint, sampleMenu, sampleSelected].forEach { $0.textColor = text }
        sampleMenu.backgroundColor = UIColor(argb: t.panel)
        sampleSelected.backgroundColor = UIColor(argb: t.focus)
        sampleSelected.layer.borderWidth = 1
        sampleSelected.layer.borderColor = text.cgColor
        whiteButton.isSelected = !black
        blackButton.isSelected = black
        for (n, b) in swatches.enumerated() {
            let chosen = AppearanceViewController.colours[n] == t.base
            b.layer.borderWidth = chosen ? 2 : 0
            b.layer.borderColor = Ui.text.cgColor
        }
    }
}

// MARK: - Screensaver settings

final class ScreensaverSettingsViewController: PageViewController {
    static let minuteChoices = [0, 2, 5, 10, 15]
    static let labels = ["Off", "2 minutes", "5 minutes", "10 minutes", "15 minutes"]

    static func minutes() -> Int {
        let m = Prefs.named("appearance").int("idle_minutes", 5)
        return minuteChoices.contains(m) ? m : 5
    }

    static func delay() -> TimeInterval { return TimeInterval(minutes() * 60) }

    private let hint = Ui.label("A quiet screen when you leave the menus idle. Your iPhone's Auto-Lock setting still applies.\nIt never appears during playback.", 14, nil, lines: 0)
    private let delayButton = LMButton("")
    private let about = Ui.label("Light Media logo + local time · dimmed, with smooth movement", 14, nil, lines: 1)
    private let previewButton = LMButton("Preview screensaver")
    private let doneButton = LMButton("Back to Settings")

    override var pageTitle: String { return "Screensaver" }

    override func viewDidLoad() {
        super.viewDidLoad()
        hint.textColor = Ui.muted
        about.textColor = Ui.muted
        delayButton.action = { [weak self] in self?.chooseDelay() }
        previewButton.action = { IdleMonitor.shared.showScreensaver() }
        doneButton.action = { [weak self] in self?.close() }
        let viewGroup3: [UIView] = [hint, delayButton, about, previewButton, doneButton]
        viewGroup3.forEach { content.addSubview($0) }
        content.onLayout = { [weak self] pane in
            guard let self = self else { return }
            let w = pane.bounds.width
            self.hint.frame = CGRect(x: 0, y: 6, width: w, height: 54)
            self.delayButton.frame = CGRect(x: 0, y: 66, width: w, height: Ui.row)
            self.about.frame = CGRect(x: 0, y: 66 + Ui.row + 4, width: w, height: 24)
            self.previewButton.frame = CGRect(x: 0, y: 66 + Ui.row + 34, width: w, height: Ui.row)
            self.doneButton.frame = CGRect(x: 0, y: 66 + Ui.row * 2 + 40, width: w, height: Ui.row)
        }
        refresh()
    }

    private func refresh() {
        let m = ScreensaverSettingsViewController.minutes()
        delayButton.title = "Start after: " + (m == 0 ? "Off" : "\(m) minutes")
    }

    private func chooseDelay() {
        let choices = ScreensaverSettingsViewController.minuteChoices
        let chosen = choices.firstIndex(of: ScreensaverSettingsViewController.minutes()) ?? 2
        Ui.choose(self, title: "Start screensaver after", items: ScreensaverSettingsViewController.labels, selected: chosen) { [weak self] n in
            Prefs.named("appearance").putInt("idle_minutes", choices[n])
            self?.refresh()
            IdleMonitor.shared.reset()
        }
    }
}

// MARK: - Profiles

final class ProfilesViewController: PageViewController {
    private let profiles = Profiles()
    private var board: TileBoardView?

    override var pageTitle: String { return "Profiles" }
    override var pageSubtitle: String { return "Save and load named settings on this iPhone. Save again to keep later changes." }

    override func viewDidLoad() {
        super.viewDidLoad()
        show()
    }

    private func show() {
        board?.removeFromSuperview()
        let created = TileBoardView(heading: "PROFILES")
        created.rail("Save current profile", selected: false) { [weak self] in self?.name(nil, rename: false) }
        created.rail("What is saved?", selected: false) { [weak self] in
            guard let self = self else { return }
            Ui.message(self, title: "Your saved profile",
                       message: "Colours, text choice, screensaver, subtitle choices, menu sections, category and station choices, favourites and watch history.\n\nProfiles belong to the current provider login and stay on this iPhone. The provider login itself is shared. This is a manual snapshot, not an automatic or portable backup.")
        }
        let list = profiles.list()
        for entry in list {
            created.add(Json.str(entry, "name"), glyph: "profile") { [weak self] in self?.options(entry) }
        }
        if list.isEmpty {
            created.add("Save your first profile", glyph: "list") { [weak self] in self?.name(nil, rename: false) }
        }
        content.addSubview(created)
        content.onLayout = { pane in created.frame = pane.bounds }
        content.setNeedsLayout()
        board = created
    }

    private func report(_ error: Error) {
        statusLabel.text = (error as? UserError)?.message ?? "Could not complete this operation."
    }

    private func name(_ saved: [String: Any]?, rename: Bool) {
        Ui.input(self, title: rename ? "Rename profile" : "Save current profile",
                 text: saved.map { Json.str($0, "name") } ?? "", placeholder: "Profile name") { [weak self] title in
            guard let self = self else { return }
            do {
                if rename, let saved = saved { try self.profiles.rename(Json.str(saved, "id"), title) }
                else { try self.profiles.save(title, replace: false) }
                self.show()
                self.statusLabel.text = "Profile saved."
            } catch { self.report(error) }
        }
    }

    private func options(_ entry: [String: Any]) {
        let id = Json.str(entry, "id"), name = Json.str(entry, "name")
        Ui.choose(self, title: name, items: ["Load profile", "Replace with current settings", "Rename", "Delete"], cancel: "Close") { [weak self] n in
            guard let self = self else { return }
            switch n {
            case 0:
                Ui.confirm(self, title: "Load " + name + "?",
                           message: "This replaces your current settings and browsing choices with the saved snapshot. Save your current setup first if you want to keep it.",
                           ok: "Load") { [weak self] in
                    guard let self = self else { return }
                    do {
                        try self.profiles.load(id)
                        Ui.load()
                        self.show()
                        self.statusLabel.text = name + " loaded."
                    } catch { self.report(error) }
                }
            case 1:
                Ui.confirm(self, title: "Replace " + name + "?", message: "Save the current setup over this snapshot?", ok: "Replace") { [weak self] in
                    guard let self = self else { return }
                    do {
                        try self.profiles.save(name, replace: true)
                        self.show()
                        self.statusLabel.text = "Profile updated."
                    } catch { self.report(error) }
                }
            case 2:
                self.name(entry, rename: true)
            default:
                Ui.confirm(self, title: "Delete " + name + "?", message: "Only this saved profile will be removed.", ok: "Delete") { [weak self] in
                    guard let self = self else { return }
                    do { try self.profiles.delete(id); self.show() } catch { self.report(error) }
                }
            }
        }
    }
}

// MARK: - Customise browsing

/// One draft for sections, categories and titles; nothing is applied until Save.
final class CustomiseViewController: PageViewController, UITableViewDataSource, UITableViewDelegate {
    private static let pageSize = 48
    private let store = LocalStore.shared
    private var provider: Provider?

    private var mainOrder = MainSections.order()
    private var hiddenMain = MainSections.hidden()
    private var categoryLists: [Kind: [MediaCategory]] = [:]
    private var hiddenCategories: [Kind: Set<String>] = [:]
    private var catalogues: [Kind: [MediaItem]] = [:]
    private var hiddenItems: [Kind: Set<String>] = [:]
    private var section = "Main sections"
    private var kind: Kind?
    private var category = ""
    private var page = 0
    private var pages = 1
    private var displayed: [MediaCategory] = []
    private var shown: [MediaItem] = []
    private var dirty = false
    private var generation = 0

    private let toolsButton = LMButton("Options")
    private var sectionButtons: [LMButton] = []
    private let headings = ["1  SECTION", "2  CATEGORY", "3  CHANNELS / ITEMS"].map { Ui.label($0, 12, nil, lines: 1) }
    private let categoryTable = UITableView(frame: .zero, style: .plain)
    private let itemTable = UITableView(frame: .zero, style: .plain)
    private let heading = Ui.label("Loading…", 16, nil, lines: 1)
    private var actionButtons: [LMButton] = []
    private let cancelButton = LMButton("Cancel", size: 16)
    private let saveButton = LMButton("Save and apply", size: 16)

    override var pageTitle: String { return "Customise browsing" }
    override var pageSubtitle: String { return "Tap a box to show or hide · Hold a row to reorder" }
    override var showsBack: Bool { return false }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let c = try? store.account() { provider = Provider(c) }
        for k in [Kind.LIVE, Kind.MOVIE, Kind.SERIES] {
            hiddenCategories[k] = store.hidden(k)
            hiddenItems[k] = k == .LIVE ? store.hiddenStations() : store.hiddenTitles(k)
        }
        toolsButton.action = { [weak self] in self?.tools() }
        view.addSubview(toolsButton)
        for title in ["Main sections", "Live TV", "Films", "Series"] {
            let b = LMButton(title, size: 15) { [weak self] in self?.load(title) }
            b.alignLeft()
            b.accessibilityIdentifier = title
            sectionButtons.append(b)
            content.addSubview(b)
        }
        headings.forEach { $0.textColor = Ui.muted; content.addSubview($0) }
        for table in [categoryTable, itemTable] {
            table.dataSource = self
            table.delegate = self
            table.backgroundColor = .clear
            table.separatorStyle = .none
            table.rowHeight = 44
            table.register(PanelCell.self, forCellReuseIdentifier: "row")
            table.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
            content.addSubview(table)
        }
        content.addSubview(heading)
        let labels = ["Select all", "Deselect all", "‹ Previous", "Next ›"]
        for (n, label) in labels.enumerated() {
            let b = LMButton(label, size: 13) { [weak self] in self?.action(n) }
            actionButtons.append(b)
            content.addSubview(b)
        }
        cancelButton.action = { [weak self] in self?.leave() }
        saveButton.action = { [weak self] in self?.save(exit: true) }
        content.addSubview(cancelButton)
        content.addSubview(saveButton)
        content.onLayout = { [weak self] pane in self?.layout(pane) }
        load("Main sections")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let r = pageRect
        toolsButton.frame = CGRect(x: r.maxX - 90, y: r.minY + 4, width: 90, height: 36)
    }

    private func layout(_ pane: Pane) {
        let w = pane.bounds.width, footerTop = pane.bounds.height - 40
        let first = (w * 0.23).rounded(), second = (w * 0.27).rounded()
        let x2 = first, x3 = first + second
        headings[0].frame = CGRect(x: 0, y: 0, width: first - 12, height: 22)
        headings[1].frame = CGRect(x: x2, y: 0, width: second - 12, height: 22)
        headings[2].frame = CGRect(x: x3, y: 0, width: w - x3, height: 22)
        for (n, b) in sectionButtons.enumerated() {
            b.frame = CGRect(x: 0, y: 24 + CGFloat(n) * 44, width: first - 12, height: 40)
        }
        let listHeight = max(0, footerTop - 6 - 24)
        categoryTable.frame = CGRect(x: x2, y: 24, width: second - 12, height: listHeight)
        heading.frame = CGRect(x: x3, y: 22, width: w - x3, height: 24)
        itemTable.frame = CGRect(x: x3, y: 48, width: w - x3, height: max(0, listHeight - 24 - 40))
        let each = (w - x3 - 3 * 4) / 4
        for (n, b) in actionButtons.enumerated() {
            b.frame = CGRect(x: x3 + CGFloat(n) * (each + 4), y: itemTable.frame.maxY + 4, width: each, height: 34)
        }
        let half = (w - 6) / 2
        cancelButton.frame = CGRect(x: 0, y: footerTop, width: half, height: 40)
        saveButton.frame = CGRect(x: half + 6, y: footerTop, width: half, height: 40)
    }

    // MARK: loading

    private func load(_ title: String) {
        page = 0
        section = title
        kind = title == "Live TV" ? .LIVE : title == "Films" ? .MOVIE : title == "Series" ? .SERIES : nil
        for b in sectionButtons { b.isSelected = b.accessibilityIdentifier == title }
        generation += 1
        let ticket = generation
        guard let requested = kind else {
            displayed = []
            shown = []
            heading.text = "Main sections"
            statusLabel.text = "Tap to show or hide a menu heading · Hold to reorder"
            categoryTable.reloadData()
            itemTable.reloadData()
            updateActions()
            return
        }
        statusLabel.text = "Tap a category to see its titles · Tap a box to show or hide · Hold to reorder"
        if categoryLists[requested] != nil && catalogues[requested] != nil {
            refreshCategories()
            showItems()
            return
        }
        heading.text = "Loading…"
        displayed = []
        shown = []
        categoryTable.reloadData()
        itemTable.reloadData()
        let source = provider
        Task { [weak self] in
            do {
                let cats: [MediaCategory]
                let items: [MediaItem]
                if let source = source {
                    cats = try await source.categories(requested)
                    items = try await source.catalogue(requested, "")
                } else {
                    cats = Demo.categories()
                    items = Demo.catalogue(requested)
                }
                guard let self = self, ticket == self.generation else { return }
                self.categoryLists[requested] = self.store.ordered(requested, cats)
                self.catalogues[requested] = self.store.orderedItems(requested, items)
                self.refreshCategories()
                self.showItems()
            } catch {
                guard let self = self, ticket == self.generation else { return }
                self.heading.text = "Could not load"
                self.statusLabel.text = safeError(error)
            }
        }
    }

    private func refreshCategories() {
        guard let kind = kind else { return }
        displayed = [MediaCategory(id: "", name: "All categories")] + (categoryLists[kind] ?? []).filter { !$0.id.isEmpty }
        if !displayed.contains(where: { $0.id == category }) { category = "" }
        categoryTable.reloadData()
    }

    private func showItems() {
        guard let kind = kind else { return }
        let name = displayed.first { $0.id == category && !category.isEmpty }?.name ?? "All titles"
        let filtered = (catalogues[kind] ?? []).filter { category.isEmpty || category == $0.category }
        pages = max(1, (filtered.count + CustomiseViewController.pageSize - 1) / CustomiseViewController.pageSize)
        page = max(0, min(page, pages - 1))
        let start = page * CustomiseViewController.pageSize
        shown = Array(filtered[min(start, filtered.count)..<min(start + CustomiseViewController.pageSize, filtered.count)])
        heading.text = "\(name) · \(page + 1) / \(pages)"
        itemTable.reloadData()
        updateActions()
    }

    private func updateActions() {
        actionButtons[0].title = kind == nil ? "Show all" : "Select all"
        actionButtons[1].title = kind == nil ? "Hide all" : "Deselect all"
        actionButtons[2].isEnabled = kind != nil && page > 0
        actionButtons[3].isEnabled = kind != nil && page < pages - 1
    }

    private func action(_ n: Int) {
        if let kind = kind {
            var hidden = hiddenItems[kind] ?? []
            switch n {
            case 0: shown.forEach { hidden.remove($0.id) }; dirty = true
            case 1: shown.forEach { hidden.insert($0.id) }; dirty = true
            case 2: if page > 0 { page -= 1 }
            default: if page < pages - 1 { page += 1 }
            }
            hiddenItems[kind] = hidden
            showItems()
            if n >= 2 { itemTable.setContentOffset(.zero, animated: false) }
        } else if n == 0 {
            hiddenMain.removeAll(); dirty = true; itemTable.reloadData()
        } else if n == 1 {
            hiddenMain = Set(MainSections.ids.filter { $0 != "Settings" }); dirty = true; itemTable.reloadData()
        }
    }

    // MARK: tables

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView === categoryTable { return kind == nil ? 1 : displayed.count }
        return kind == nil ? mainOrder.count : shown.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        guard let row = cell as? PanelCell else { return cell }
        let n = indexPath.row
        row.bottomGap = 4
        row.onCheckTap = nil
        if tableView === categoryTable {
            guard let kind = kind else {
                row.title.text = "Main menu headings"
                row.showsCheck = false
                row.activated = true
                return row
            }
            let c = displayed[n]
            row.title.text = c.name
            row.activated = c.id == category
            row.showsCheck = !c.id.isEmpty
            row.check.checked = c.id.isEmpty || !(hiddenCategories[kind]?.contains(c.id) ?? false)
            if !c.id.isEmpty {
                row.onCheckTap = { [weak self] in self?.toggleCategory(c) }
            }
            return row
        }
        row.activated = false
        row.showsCheck = true
        if let kind = kind {
            row.title.text = shown[n].name
            row.check.checked = !(hiddenItems[kind]?.contains(shown[n].id) ?? false)
        } else {
            row.title.text = MainSections.title(mainOrder[n])
            row.check.checked = !hiddenMain.contains(mainOrder[n])
        }
        return row
    }

    private func toggleCategory(_ c: MediaCategory) {
        guard let kind = kind else { return }
        var hidden = hiddenCategories[kind] ?? []
        if hidden.contains(c.id) { hidden.remove(c.id) } else { hidden.insert(c.id) }
        hiddenCategories[kind] = hidden
        dirty = true
        categoryTable.reloadData()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let n = indexPath.row
        if tableView === categoryTable {
            guard kind != nil, n < displayed.count else { return }
            if category != displayed[n].id { page = 0 }
            category = displayed[n].id
            categoryTable.reloadData()
            showItems()
            return
        }
        if let kind = kind {
            guard n < shown.count else { return }
            var hidden = hiddenItems[kind] ?? []
            if hidden.contains(shown[n].id) { hidden.remove(shown[n].id) } else { hidden.insert(shown[n].id) }
            hiddenItems[kind] = hidden
        } else {
            let id = mainOrder[n]
            if id == "Settings" {
                Ui.toast("Settings always stays in the menu.")
                return
            }
            if hiddenMain.contains(id) { hiddenMain.remove(id) } else { hiddenMain.insert(id) }
        }
        dirty = true
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let table = g.view as? UITableView,
              let path = table.indexPathForRow(at: g.location(in: table)) else { return }
        let n = path.row
        if table === categoryTable {
            guard let kind = kind, n < displayed.count, !displayed[n].id.isEmpty else { return }
            let c = displayed[n]
            reorder(c.name) { [weak self] delta in self?.moveCategory(kind, c, delta) }
        } else if kind != nil {
            guard n < shown.count else { return }
            reorder(shown[n].name) { [weak self] delta in self?.moveItem(n, delta) }
        } else {
            reorder(MainSections.title(mainOrder[n])) { [weak self] delta in self?.moveItem(n, delta) }
        }
    }

    private func reorder(_ title: String, _ move: @escaping (Int) -> Void) {
        Ui.choose(self, title: title, items: ["Move up", "Move down", "Move to top"]) { n in
            move(n == 0 ? -1 : n == 1 ? 1 : -10_000)
        }
    }

    private func moveCategory(_ kind: Kind, _ c: MediaCategory, _ delta: Int) {
        guard var list = categoryLists[kind], let from = list.firstIndex(of: c) else { return }
        let firstReal = list.first?.id.isEmpty == true ? 1 : 0
        let to = max(firstReal, min(list.count - 1, from + delta))
        list.remove(at: from)
        list.insert(c, at: to)
        categoryLists[kind] = list
        dirty = true
        category = c.id
        refreshCategories()
        showItems()
    }

    private func moveItem(_ at: Int, _ delta: Int) {
        if let kind = kind {
            guard var all = catalogues[kind], at < shown.count else { return }
            let to = max(0, min(shown.count - 1, at + delta))
            let item = shown[at], target = shown[to]
            guard let from = all.firstIndex(of: item), let dest = all.firstIndex(of: target) else { return }
            all.remove(at: from)
            all.insert(item, at: dest)
            catalogues[kind] = all
            dirty = true
            showItems()
        } else {
            let to = max(0, min(mainOrder.count - 1, at + delta))
            let id = mainOrder.remove(at: at)
            mainOrder.insert(id, at: to)
            dirty = true
            itemTable.reloadData()
        }
    }

    // MARK: tools, saving and leaving

    private func tools() {
        Ui.choose(self, title: "Browsing tools", items: ["Manage channel duplicates", "Restore all categories"], cancel: "Close") { [weak self] n in
            guard let self = self else { return }
            if n == 1 {
                Ui.confirm(self, title: "Show all categories again?", ok: "Restore") { [weak self] in
                    guard let self = self else { return }
                    for k in [Kind.LIVE, Kind.MOVIE, Kind.SERIES] { self.hiddenCategories[k] = [] }
                    self.dirty = true
                    self.categoryTable.reloadData()
                    Ui.toast("All categories restored. Save to apply.")
                }
            } else if self.kind == .LIVE {
                self.duplicates()
            } else {
                Ui.message(self, title: "Channel duplicates", message: "Select Live TV first.")
            }
        }
    }

    private func duplicates() {
        var order: [String] = []
        var groups: [String: [MediaItem]] = [:]
        for i in shown {
            var key = i.name.lowercased().replacingOccurrences(of: "\\b(hd|sd|fhd|uhd|4k)\\b", with: "", options: .regularExpression)
            key = key.replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(i)
        }
        let matches = order.compactMap { groups[$0] }.filter { $0.count > 1 }
        if matches.isEmpty {
            Ui.message(self, title: "No matching names found",
                       message: "Only channels in the shown category were checked. You can still select channels individually.")
            return
        }
        let labels = matches.map { "\($0[0].name) · \($0.count) versions" }
        Ui.choose(self, title: "Choose a group to review", items: labels) { [weak self] n in
            guard let self = self else { return }
            let group = matches[n]
            Ui.choose(self, title: "Keep which version?", items: group.map { $0.name + " · " + $0.id }) { [weak self] index in
                guard let self = self else { return }
                var hidden = self.hiddenItems[.LIVE] ?? []
                group.forEach { hidden.insert($0.id) }
                hidden.remove(group[index].id)
                self.hiddenItems[.LIVE] = hidden
                self.dirty = true
                self.showItems()
            }
        }
    }

    private func save(exit: Bool) {
        for (k, list) in categoryLists {
            store.setHidden(k, hiddenCategories[k] ?? [])
            store.order(k, list)
        }
        for k in [Kind.LIVE, Kind.MOVIE, Kind.SERIES] where categoryLists[k] == nil {
            store.setHidden(k, hiddenCategories[k] ?? [])
        }
        for (k, items) in catalogues { store.saveBrowsingItems(k, items, hiddenItems[k] ?? []) }
        MainSections.save(order: mainOrder, hidden: hiddenMain)
        dirty = false
        Prefs.flushAll()
        if exit { close() }
    }

    private func leave() {
        if !dirty { close(); return }
        Ui.ask(self, title: "Save browsing changes?", yes: "Save and apply", no: "Discard changes", cancel: "Keep editing",
               onYes: { [weak self] in self?.save(exit: true) }, onNo: { [weak self] in self?.close() })
    }
}
