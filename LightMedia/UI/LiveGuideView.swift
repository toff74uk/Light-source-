import UIKit

protocol LiveGuideActions: AnyObject {
    func guidePlay(_ item: MediaItem)
    func guideOptions(_ item: MediaItem)
    func guideHighlight(_ item: MediaItem, _ programme: Programme?, _ status: String)
}

/// A two-hour, time-aligned guide. Only rows on screen fetch listings; playback never waits.
final class LiveGuideView: UIView, UITableViewDataSource, UITableViewDelegate {
    static let half: Int64 = 30 * 60_000
    static let span: Int64 = 4 * half
    static let refreshSeconds: TimeInterval = 120
    static let lookBehind: Int64 = 15 * 60_000
    static let channelWidth: CGFloat = 142

    fileprivate struct Entry {
        let programmes: [Programme]
        let at: Int64
        let failed: Bool
    }

    private let provider: Provider?
    private let channels: [MediaItem]
    weak var actions: LiveGuideActions?
    var extra: CGFloat = 0
    var onPageState: ((Bool, Bool) -> Void)?

    private let range = Ui.label("", 12, nil, lines: 1)
    private let channelHeading = Ui.label("CHANNEL", 10, nil, lines: 1)
    private let axis = GuideAxisView()
    private let table = UITableView(frame: .zero, style: .plain)
    private var geometry = RowGeometry(viewport: 44, preferred: 44)

    private var cache: [String: Entry] = [:]
    private var cacheOrder: [String] = []
    private var pending = Set<String>()
    private var waiting: [MediaItem] = []
    private var running = 0
    private var sampledNow = nowMillis()
    fileprivate var windowStart = nowMillis() - LiveGuideView.lookBehind
    fileprivate var page = 0
    private var active = true
    private var closed = false
    private var timer: Timer?
    fileprivate var highlightChannel = ""
    fileprivate var highlightStart: Int64 = -1

    init(provider: Provider?, channels: [MediaItem]) {
        self.provider = provider
        self.channels = channels
        super.init(frame: .zero)
        range.textColor = Ui.cyan
        channelHeading.textColor = Ui.muted
        axis.guide = self
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.showsVerticalScrollIndicator = false
        table.bounces = false
        table.decelerationRate = .fast
        table.register(GuideCell.self, forCellReuseIdentifier: "row")
        let viewGroup1: [UIView] = [range, channelHeading, axis, table]
        viewGroup1.forEach { addSubview($0) }
        refreshTime(nowMillis())
        redraw()
        timer = Timer.scheduledTimer(withTimeInterval: LiveGuideView.refreshSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        range.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 26)
        channelHeading.frame = CGRect(x: 10, y: 26, width: LiveGuideView.channelWidth - 10, height: 20)
        axis.frame = CGRect(x: LiveGuideView.channelWidth, y: 26, width: max(0, bounds.width - LiveGuideView.channelWidth), height: 20)
        let frame = CGRect(x: 0, y: 46, width: bounds.width, height: max(0, bounds.height - 46))
        if table.frame != frame {
            table.frame = frame
            geometry = RowGeometry(viewport: frame.height, preferred: Ui.row, extra: extra)
            table.rowHeight = geometry.pitch
            table.reloadData()
        }
    }

    // MARK: time window

    func showEarlier() { shift(-1) }
    func showLater() { shift(1) }
    func showNow() { page = 0; refreshTime(nowMillis()); redraw() }

    private func shift(_ by: Int) {
        page = max(0, min(2, page + by))
        refreshTime(nowMillis())
        redraw()
    }

    // The displayed "now" is sampled with the grid: both advance together, never drift apart.
    private func refreshTime(_ now: Int64) {
        sampledNow = now
        windowStart = now - LiveGuideView.lookBehind + Int64(page) * LiveGuideView.span
    }

    fileprivate var nowFraction: CGFloat {
        return CGFloat(sampledNow - windowStart) / CGFloat(LiveGuideView.span)
    }

    private func redraw() {
        onPageState?(page > 0, page < 2)
        let format = DateFormatter()
        format.dateFormat = "EEE d MMM"
        range.text = format.string(from: Date(timeIntervalSince1970: Double(windowStart) / 1000))
        axis.setNeedsDisplay()
        for case let cell as GuideCell in table.visibleCells { cell.strip.setNeedsDisplay() }
    }

    private func refresh() {
        if closed { return }
        refreshTime(nowMillis())
        redraw()
        if active {
            for case let cell as GuideCell in table.visibleCells {
                if let item = cell.item { request(item) }
            }
        }
    }

    func pause() { active = false }

    func resume() {
        if closed { return }
        active = true
        refresh()
    }

    func close() {
        closed = true
        active = false
        timer?.invalidate()
        timer = nil
        waiting.removeAll()
        cache.removeAll()
    }

    func reloadRows() { table.reloadData() }

    func scroll(to id: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }), table.rowHeight > 0 else { return }
        layoutIfNeeded()
        let first = max(0, min(max(0, channels.count - geometry.visible), index / geometry.visible * geometry.visible))
        table.setContentOffset(CGPoint(x: 0, y: CGFloat(first) * geometry.pitch), animated: false)
        highlightChannel = id
        highlightStart = -1
        for case let cell as GuideCell in table.visibleCells { cell.refreshSelection() }
    }

    // MARK: listings

    private func request(_ item: MediaItem) {
        if closed || !active { return }
        if let known = cache[item.id], nowMillis() - known.at < (known.failed ? 30_000 : 120_000) { return }
        guard provider != nil else {
            store(item.id, Entry(programmes: Epg.demo(item, nowMillis()), at: nowMillis(), failed: false))
            return
        }
        if pending.contains(item.id) { return }
        pending.insert(item.id)
        waiting.append(item)
        if waiting.count > 12 {
            let dropped = waiting.removeFirst()
            pending.remove(dropped.id)
        }
        pump()
    }

    private func pump() {
        guard let source = provider else { return }
        while running < 2, !waiting.isEmpty {
            let next = waiting.removeLast()
            running += 1
            Task { [weak self] in
                var data: [Programme] = []
                var failed = false
                do { data = try await source.programmes(next) } catch { failed = true }
                guard let self = self else { return }
                self.running -= 1
                self.pending.remove(next.id)
                if !self.closed {
                    self.store(next.id, Entry(programmes: data, at: nowMillis(), failed: failed))
                    for case let cell as GuideCell in self.table.visibleCells where cell.item?.id == next.id {
                        cell.strip.setNeedsDisplay()
                    }
                    if self.highlightChannel == next.id { self.describe(next, nil) }
                }
                self.pump()
            }
        }
    }

    private func store(_ id: String, _ entry: Entry) {
        if cache[id] == nil {
            cacheOrder.append(id)
            if cacheOrder.count > 100 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
        cache[id] = entry
    }

    fileprivate func visible(_ item: MediaItem) -> [Programme] {
        guard let entry = cache[item.id] else { return [] }
        return entry.programmes.filter { $0.overlaps(windowStart, windowStart + LiveGuideView.span) }
    }

    fileprivate func emptyText(_ item: MediaItem) -> String {
        guard let entry = cache[item.id] else { return "Loading guide…" }
        return entry.failed ? "Guide unavailable · Tap the channel to watch" : "No programme information"
    }

    private func describe(_ item: MediaItem, _ chosen: Programme?) {
        let entry = cache[item.id]
        var programme = chosen
        if programme == nil, let entry = entry {
            let now = nowMillis()
            programme = entry.programmes.first { $0.start <= now && $0.end > now }
        }
        let status = entry == nil ? "Loading guide…" : (entry?.failed ?? false) ? "Guide unavailable" : "No listings"
        actions?.guideHighlight(item, programme, status)
    }

    fileprivate func channelTapped(_ item: MediaItem) {
        highlightChannel = item.id
        highlightStart = -1
        for case let cell as GuideCell in table.visibleCells { cell.refreshSelection() }
        describe(item, nil)
        actions?.guidePlay(item)
    }

    fileprivate func programmeTapped(_ item: MediaItem, _ programme: Programme?) {
        highlightChannel = item.id
        highlightStart = programme?.start ?? -1
        for case let cell as GuideCell in table.visibleCells { cell.refreshSelection() }
        describe(item, programme)
        guard let p = programme else { actions?.guidePlay(item); return }
        guard let host = Ui.top() else { return }
        let text = item.name + "\n" + p.times() + "\n\n" + (p.description.isEmpty ? "No synopsis supplied." : p.description)
            + "\n\nWatch channel opens the live broadcast."
        Ui.confirm(host, title: p.title, message: text, ok: "Watch channel", cancel: "Close") { [weak self] in
            self?.actions?.guidePlay(item)
        }
    }

    fileprivate func held(_ item: MediaItem) { actions?.guideOptions(item) }

    // MARK: table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return channels.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        guard let row = cell as? GuideCell else { return cell }
        row.guide = self
        row.bind(channels[indexPath.row])
        return row
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        request(channels[indexPath.row])
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee.y = geometry.snapped(targetContentOffset.pointee.y, rows: channels.count)
    }
}

/// Half-hour labels above the programme strips.
final class GuideAxisView: UIView {
    weak var guide: LiveGuideView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let guide = guide else { return }
        let font = UIFont.systemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Ui.muted]
        let half = LiveGuideView.half, span = LiveGuideView.span
        var time = (guide.windowStart / half + 1) * half
        while time < guide.windowStart + span {
            let x = CGFloat(time - guide.windowStart) * bounds.width / CGFloat(span)
            let label = Epg.clock.string(from: Date(timeIntervalSince1970: Double(time) / 1000)) as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: CGPoint(x: min(x + 4, bounds.width - width - 2), y: bounds.height - font.lineHeight - 1),
                       withAttributes: attributes)
            time += half
        }
    }
}

/// One channel's programmes across the visible window.
final class GuideStripView: UIView {
    weak var guide: LiveGuideView?
    var item: MediaItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        clipsToBounds = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func span(_ p: Programme, _ start: Int64) -> (left: CGFloat, right: CGFloat) {
        let w = bounds.width, total = CGFloat(LiveGuideView.span)
        return (max(0, CGFloat(p.start - start) * w / total), min(w, CGFloat(p.end - start) * w / total))
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let guide = guide, let item = item else { return }
        let x = g.location(in: self).x
        let hit = guide.visible(item).first { p in
            let s = span(p, guide.windowStart)
            return x >= s.left && x < s.right
        }
        guide.programmeTapped(item, hit)
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        if g.state == .began, let item = item { guide?.held(item) }
    }

    override func draw(_ rect: CGRect) {
        guard let guide = guide, let item = item else { return }
        let w = bounds.width, h = bounds.height
        let list = guide.visible(item)
        let selectedRow = guide.highlightChannel == item.id
        let titleFont = UIFont.systemFont(ofSize: 12, weight: .medium)
        let timeFont = UIFont.systemFont(ofSize: 10)
        if list.isEmpty {
            Ui.panel.setFill()
            UIBezierPath(rect: CGRect(x: 2, y: 1, width: max(0, w - 3), height: max(0, h - 2))).fill()
            (guide.emptyText(item) as NSString).draw(at: CGPoint(x: 12, y: (h - 15) / 2),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: Ui.muted])
        }
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for p in list {
            let s = span(p, guide.windowStart)
            let block = CGRect(x: s.left + 2, y: 2, width: max(0, s.right - 1 - s.left - 2), height: max(0, h - 4))
            let focused = selectedRow && guide.highlightStart == p.start
            let path = UIBezierPath(roundedRect: block, cornerRadius: 2)
            (focused ? UIColor(argb: Theme.shade(Ui.palette.base, 0.75)) : Ui.panel).setFill()
            path.fill()
            if focused {
                Ui.cyan.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: s.left + 8, y: 0, width: max(0, s.right - 7 - s.left - 8), height: h))
            (p.title as NSString).draw(at: CGPoint(x: s.left + 9, y: h * 0.43 - titleFont.ascender),
                                       withAttributes: [.font: titleFont, .foregroundColor: Ui.text])
            (p.times() as NSString).draw(at: CGPoint(x: s.left + 9, y: h * 0.74 - timeFont.ascender),
                                         withAttributes: [.font: timeFont, .foregroundColor: Ui.muted])
            ctx.restoreGState()
        }
        if guide.page == 0 {
            let x = guide.nowFraction * w
            Ui.text.setStroke()
            let line = UIBezierPath()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: h))
            line.lineWidth = 1
            line.stroke()
        }
    }
}

final class GuideCell: UITableViewCell {
    weak var guide: LiveGuideView?
    private(set) var item: MediaItem?
    let channel = LMButton("", size: 14)
    let strip = GuideStripView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none
        channel.alignLeft()
        channel.action = { [weak self] in
            if let item = self?.item { self?.guide?.channelTapped(item) }
        }
        channel.longAction = { [weak self] in
            if let item = self?.item { self?.guide?.held(item) }
        }
        contentView.addSubview(channel)
        contentView.addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func bind(_ next: MediaItem) {
        item = next
        channel.title = next.name
        channel.accessibilityLabel = next.name + ", watch live"
        strip.guide = guide
        strip.item = next
        strip.accessibilityLabel = "Programme guide for " + next.name
        refreshSelection()
    }

    func refreshSelection() {
        channel.isSelected = guide?.highlightChannel == item?.id && item != nil
        strip.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = max(0, contentView.bounds.height - Ui.gap)
        channel.frame = CGRect(x: 0, y: 0, width: LiveGuideView.channelWidth, height: h)
        strip.frame = CGRect(x: LiveGuideView.channelWidth, y: 0,
                             width: max(0, contentView.bounds.width - LiveGuideView.channelWidth), height: h)
    }
}
