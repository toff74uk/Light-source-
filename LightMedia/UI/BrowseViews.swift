import UIKit

/// Whole rows only: the viewport is divided into an exact number of rows.
/// `extra` keeps the row count the phone layout had before the picture grew.
struct RowGeometry {
    let viewport: CGFloat
    let gap: CGFloat
    let visible: Int

    init(viewport: CGFloat, preferred: CGFloat, gap: CGFloat = Ui.gap, extra: CGFloat = 0) {
        self.viewport = max(1, viewport)
        self.gap = gap
        visible = max(1, Int(((max(1, viewport + extra) + gap) / (preferred + gap)).rounded()))
    }

    /// Distance from the top of one row to the top of the next.
    var pitch: CGFloat { return (viewport + gap) / CGFloat(visible) }
    var rowHeight: CGFloat { return pitch - gap }

    func snapped(_ offset: CGFloat, rows: Int) -> CGFloat {
        let last = max(0, rows - visible)
        let row = max(0, min(last, Int((offset / pitch).rounded())))
        return CGFloat(row) * pitch
    }
}

/// Centred status text with an optional retry button.
final class MessageView: UIView {
    private let label = Ui.label("", 16, nil, lines: 0)
    private var button: LMButton?

    init(_ text: String, size: CGFloat = 16, retry: (() -> Void)? = nil) {
        super.init(frame: .zero)
        label.text = text
        label.font = Ui.font(size)
        label.textColor = Ui.muted
        label.textAlignment = .center
        addSubview(label)
        if let retry = retry {
            let b = LMButton("Try again", action: retry)
            addSubview(b)
            button = b
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = label.sizeThatFits(CGSize(width: bounds.width - 16, height: bounds.height))
        let buttonHeight: CGFloat = button == nil ? 0 : 44 + 12
        let top = max(0, (bounds.height - text.height - buttonHeight) / 2)
        label.frame = CGRect(x: 8, y: top, width: bounds.width - 16, height: min(text.height, bounds.height))
        button?.frame = CGRect(x: bounds.midX - 80, y: label.frame.maxY + 12, width: 160, height: 44)
    }
}

// MARK: - Poster grid

final class PosterCell: UICollectionViewCell {
    let art = ArtView()
    let title = Ui.label("", 12, nil, lines: 2)
    let meta = Ui.label("", 10, nil, lines: 1)
    let progress = UIProgressView(progressViewStyle: .bar)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 2
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.75
        progress.trackTintColor = UIColor.black.withAlphaComponent(0.2)
        let viewGroup1: [UIView] = [art, title, meta, progress]
        viewGroup1.forEach { contentView.addSubview($0) }
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool { didSet { restyle() } }

    func restyle() {
        contentView.backgroundColor = isHighlighted ? Ui.focus : Ui.panel
        contentView.layer.borderWidth = isHighlighted ? 1 : 0
        contentView.layer.borderColor = Ui.text.cgColor
        title.textColor = Ui.text
        meta.textColor = Ui.muted
        progress.progressTintColor = Ui.cyan
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = contentView.bounds.width, h = contentView.bounds.height
        let showMeta = !meta.isHidden
        let artHeight = max(24, h - (showMeta ? 57 : 37))
        art.frame = CGRect(x: 5, y: 5, width: w - 10, height: artHeight)
        let progressHeight: CGFloat = progress.isHidden ? 0 : 5
        let metaHeight: CGFloat = showMeta ? 14 : 0
        let bottom = h - 6 - progressHeight
        meta.frame = CGRect(x: 5, y: bottom - metaHeight, width: w - 10, height: metaHeight)
        title.frame = CGRect(x: 5, y: art.frame.maxY + 2, width: w - 10, height: max(0, meta.frame.minY - art.frame.maxY - 2))
        progress.frame = CGRect(x: 5, y: h - 6 - 5, width: w - 10, height: 5)
    }
}

/// Paged poster and channel cards. Rows always fill the viewport exactly.
final class PosterGridView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private(set) var items: [MediaItem]
    private let artwork: Artwork
    private let store = LocalStore.shared
    private let layout: UICollectionViewFlowLayout
    private let collection: UICollectionView
    private var geometry = RowGeometry(viewport: 135, preferred: 135)
    let columns = 3
    var extra: CGFloat = 0
    var startIndex = 0
    var onTap: ((MediaItem, Int) -> Void)?
    var onHold: ((MediaItem) -> Void)?
    var onPage: ((Int, Int, Int) -> Void)?
    private var positioned = false

    init(items: [MediaItem], artwork: Artwork) {
        self.items = items
        self.artwork = artwork
        let flow = UICollectionViewFlowLayout()
        layout = flow
        collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
        super.init(frame: .zero)
        layout.minimumLineSpacing = Ui.gap
        layout.minimumInteritemSpacing = Ui.gap
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.showsVerticalScrollIndicator = false
        collection.bounces = false
        collection.decelerationRate = .fast
        collection.register(PosterCell.self, forCellWithReuseIdentifier: "card")
        collection.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        addSubview(collection)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var rows: Int { return (items.count + columns - 1) / columns }
    var pageRows: Int { return geometry.visible }

    override func layoutSubviews() {
        super.layoutSubviews()
        if collection.frame.size == bounds.size && positioned { return }
        collection.frame = bounds
        geometry = RowGeometry(viewport: bounds.height, preferred: 135, extra: extra)
        layout.invalidateLayout()
        if bounds.height > 0 {
            collection.layoutIfNeeded()
            let row = max(0, startIndex) / columns
            let first = min(max(0, rows - geometry.visible), row / geometry.visible * geometry.visible)
            collection.contentOffset = CGPoint(x: 0, y: CGFloat(first) * geometry.pitch)
            positioned = true
            report()
        }
    }

    func reload() { collection.reloadData() }

    /// Index of the first card on screen, remembered for "return to where I was".
    var firstVisibleIndex: Int {
        return max(0, Int((collection.contentOffset.y / geometry.pitch).rounded())) * columns
    }

    func page(by direction: Int) {
        let row = Int((collection.contentOffset.y / geometry.pitch).rounded())
        let target = (row / geometry.visible + direction) * geometry.visible
        let clamped = max(0, min(max(0, rows - geometry.visible), target))
        collection.setContentOffset(CGPoint(x: 0, y: CGFloat(clamped) * geometry.pitch), animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.report() }
    }

    private func report() {
        let size = max(1, geometry.visible)
        let row = Int((collection.contentOffset.y / geometry.pitch).rounded())
        let pages = max(1, (rows + size - 1) / size)
        let page = min(pages, Int((Double(row) / Double(size)).rounded(.up)) + 1)
        onPage?(page, pages, items.count)
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let path = collection.indexPathForItem(at: g.location(in: collection)) else { return }
        onHold?(items[path.item])
    }

    private func progressLabel(_ item: MediaItem) -> String {
        if store.watched(item) { return "✓ Watched" }
        let pos = store.position(item), duration = store.duration(item)
        if pos <= 0 { return "" }
        if duration > 0 {
            return "\(Int(min(100, 100.0 * Double(pos) / Double(duration))))% · \(max(1, (duration - pos + 59_999) / 60_000)) min left"
        }
        return "Resume · \(max(1, pos / 60_000)) min in"
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { return items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath)
        guard let card = cell as? PosterCell else { return cell }
        let item = items[indexPath.item]
        card.title.text = item.kind == .EPISODE ? Media.episodeLabel(item) : item.name
        let fav = store.favourite(item) ? "♥  " : ""
        let detail = item.kind == .LIVE ? "LIVE · Tap to watch" : item.kind == .SERIES ? "" : progressLabel(item)
        card.meta.text = fav + detail
        card.meta.isHidden = (fav + detail).isEmpty
        let duration = store.duration(item), position = store.position(item)
        card.progress.isHidden = !(duration > 0 && position > 0 && !store.watched(item))
        card.progress.progress = duration > 0 ? Float(min(1, Double(position) / Double(duration))) : 0
        card.accessibilityLabel = item.name + (store.favourite(item) ? ", favourite" : "")
        card.restyle()
        artwork.load(card.art, item)
        card.setNeedsLayout()
        return card
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = ((bounds.width - CGFloat(columns - 1) * Ui.gap) / CGFloat(columns)).rounded(.down)
        return CGSize(width: max(10, width), height: max(10, geometry.rowHeight))
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        onTap?(items[indexPath.item], indexPath.item)
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee.y = geometry.snapped(targetContentOffset.pointee.y, rows: rows)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { report() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { report() } }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { report() }
}

// MARK: - Tile board

/// Shared geometry for the settings grid: a short rail on the left, tiles on the right.
final class TileBoardView: UIView, UIScrollViewDelegate {
    private let heading = Ui.label("", 10, nil, lines: 1)
    private var railButtons: [LMButton] = []
    private let scroll = UIScrollView()
    private var tiles: [UIControl] = []
    private var geometry = RowGeometry(viewport: 101, preferred: 101)
    let columns = 3
    var extra: CGFloat = 0
    var contentOnly = false

    init(heading text: String) {
        super.init(frame: .zero)
        heading.text = text
        addSubview(heading)
        scroll.showsVerticalScrollIndicator = true
        scroll.bounces = false
        scroll.decelerationRate = .fast
        scroll.delegate = self
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @discardableResult
    func rail(_ title: String, selected: Bool, action: @escaping () -> Void) -> LMButton {
        let b = LMButton(title, action: action)
        b.isSelected = selected
        addSubview(b)
        railButtons.append(b)
        return b
    }

    @discardableResult
    func add(_ title: String, glyph: String, action: @escaping () -> Void) -> UIControl {
        let tile = TileControl(title: title, glyph: glyph, action: action)
        scroll.addSubview(tile)
        tiles.append(tile)
        return tile
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let railWidth: CGFloat = contentOnly ? 0 : 106
        heading.isHidden = contentOnly
        heading.frame = CGRect(x: 10, y: 0, width: max(0, railWidth - 22), height: 30)
        var y: CGFloat = 30
        for b in railButtons {
            b.isHidden = contentOnly
            b.frame = CGRect(x: 0, y: y, width: max(0, railWidth - 12), height: 38)
            y += 38 + Ui.gap
        }
        let top: CGFloat = contentOnly ? 0 : 30
        scroll.frame = CGRect(x: railWidth, y: top, width: bounds.width - railWidth, height: max(0, bounds.height - top))
        geometry = RowGeometry(viewport: scroll.bounds.height, preferred: 101, extra: extra)
        let width = ((scroll.bounds.width - CGFloat(columns - 1) * Ui.gap - 6) / CGFloat(columns)).rounded(.down)
        for (n, tile) in tiles.enumerated() {
            tile.frame = CGRect(x: CGFloat(n % columns) * (width + Ui.gap), y: CGFloat(n / columns) * geometry.pitch,
                                width: width, height: geometry.rowHeight)
        }
        let rows = (tiles.count + columns - 1) / columns
        scroll.contentSize = CGSize(width: scroll.bounds.width, height: max(0, CGFloat(rows) * geometry.pitch - Ui.gap))
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let rows = (tiles.count + columns - 1) / columns
        targetContentOffset.pointee.y = geometry.snapped(targetContentOffset.pointee.y, rows: rows)
    }
}

final class TileControl: UIControl {
    private let glyph: GlyphView
    private let label = Ui.label("", 13, nil, lines: 2)
    private let action: () -> Void

    init(title: String, glyph name: String, action: @escaping () -> Void) {
        glyph = GlyphView(name)
        self.action = action
        super.init(frame: .zero)
        layer.cornerRadius = 2
        label.text = title
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        label.isUserInteractionEnabled = false
        addSubview(glyph)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool { didSet { restyle() } }

    private func restyle() {
        backgroundColor = isHighlighted ? Ui.focus : Ui.panel
        layer.borderWidth = isHighlighted ? 1 : 0
        layer.borderColor = Ui.text.cgColor
    }

    @objc private func tapped() { action() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let glyphHeight = min(46, max(20, bounds.height * 0.46))
        glyph.frame = CGRect(x: 6, y: 8, width: bounds.width - 12, height: glyphHeight)
        label.frame = CGRect(x: 6, y: glyph.frame.maxY + 4, width: bounds.width - 12, height: max(0, bounds.height - glyph.frame.maxY - 8))
    }
}

/// A list row that looks like the panel buttons, with optional check box.
final class PanelCell: UITableViewCell {
    let panel = UIView()
    let title = Ui.label("", 15, nil, lines: 2)
    let check = CheckView()
    var bottomGap: CGFloat = Ui.gap
    var showsCheck = false { didSet { check.isHidden = !showsCheck; setNeedsLayout() } }
    var activated = false { didSet { restyle() } }
    /// When set, the check box is its own touch target, separate from selecting the row.
    var onCheckTap: (() -> Void)? { didSet { checkButton.isHidden = onCheckTap == nil } }
    private let checkButton = UIButton(type: .custom)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        panel.layer.cornerRadius = 2
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.7
        check.isHidden = true
        contentView.addSubview(panel)
        panel.addSubview(title)
        panel.addSubview(check)
        checkButton.isHidden = true
        checkButton.addTarget(self, action: #selector(checkTapped), for: .touchUpInside)
        contentView.addSubview(checkButton)
        restyle()
    }

    @objc private func checkTapped() { onCheckTap?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        restyle()
    }

    func restyle() {
        title.textColor = Ui.text
        if isHighlighted {
            panel.backgroundColor = Ui.focus
            panel.layer.borderWidth = 1
            panel.layer.borderColor = Ui.text.cgColor
        } else if activated {
            panel.backgroundColor = Ui.active
            panel.layer.borderWidth = 1
            panel.layer.borderColor = Ui.activeStroke.cgColor
        } else {
            panel.backgroundColor = Ui.panel
            panel.layer.borderWidth = 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        panel.frame = CGRect(x: 0, y: 0, width: contentView.bounds.width, height: max(0, contentView.bounds.height - bottomGap))
        let checkSize: CGFloat = min(26, panel.bounds.height - 6)
        let checkSpace: CGFloat = showsCheck ? checkSize + 14 : 0
        title.frame = CGRect(x: 12, y: 0, width: max(0, panel.bounds.width - 20 - checkSpace), height: panel.bounds.height)
        check.frame = CGRect(x: panel.bounds.width - checkSize - 8, y: (panel.bounds.height - checkSize) / 2,
                             width: checkSize, height: checkSize)
        checkButton.frame = CGRect(x: panel.bounds.width - 52, y: 0, width: 52, height: panel.bounds.height)
    }
}
