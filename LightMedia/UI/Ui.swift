import UIKit

extension UIColor {
    convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 0xff) / 255, green: CGFloat((argb >> 8) & 0xff) / 255,
                  blue: CGFloat(argb & 0xff) / 255, alpha: CGFloat((argb >> 24) & 0xff) / 255)
    }
}

/// Shared look and measurements, taken from the Android phone layout.
enum Ui {
    static let row: CGFloat = 44
    static let gap: CGFloat = 6
    static let header: CGFloat = 44

    private(set) static var palette = Theme(base: Theme.blue, black: false)
    static weak var window: UIWindow?

    static var bg: UIColor { return UIColor(argb: palette.base) }
    static var panel: UIColor { return UIColor(argb: palette.panel) }
    static var text: UIColor { return UIColor(argb: palette.text) }
    static var muted: UIColor { return UIColor(argb: palette.muted) }
    static var cyan: UIColor { return UIColor(argb: palette.text) }
    static var focus: UIColor { return UIColor(argb: palette.focus) }
    static var active: UIColor { return UIColor(argb: palette.active) }
    static var activeStroke: UIColor { return UIColor(argb: Theme.shade(palette.text, 0.65)) }
    static var end: UIColor { return UIColor(argb: palette.end) }

    static func load() { palette = Theme.read() }
    static var themeKey: String { return palette.key }

    static func font(_ size: CGFloat, bold: Bool = false) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    static func label(_ text: String, _ size: CGFloat, _ color: UIColor? = nil, lines: Int = 0) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = font(size)
        l.textColor = color ?? Ui.text
        l.numberOfLines = lines
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    static func field(_ placeholder: String, secure: Bool = false) -> UITextField {
        let f = UITextField()
        f.font = font(14)
        f.textColor = Ui.text
        f.backgroundColor = Ui.panel
        f.layer.cornerRadius = 2
        f.attributedPlaceholder = NSAttributedString(string: placeholder,
            attributes: [.foregroundColor: Ui.muted.withAlphaComponent(0.6)])
        f.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        f.leftViewMode = .always
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.spellCheckingType = .no
        f.isSecureTextEntry = secure
        f.returnKeyType = .done
        f.clearButtonMode = .whileEditing
        f.keyboardAppearance = .dark
        return f
    }

    static func top() -> UIViewController? {
        var vc = window?.rootViewController
        while let next = vc?.presentedViewController, !next.isBeingDismissed { vc = next }
        return vc
    }

    // MARK: toast

    private static weak var toastView: UIView?

    static func toast(_ text: String) {
        guard let window = window else { return }
        toastView?.removeFromSuperview()
        let l = PaddedLabel()
        l.text = text
        l.font = font(14)
        l.textColor = .white
        l.numberOfLines = 3
        l.textAlignment = .center
        l.backgroundColor = UIColor(argb: 0xe613263b)
        l.layer.cornerRadius = 8
        l.layer.masksToBounds = true
        let limit = min(window.bounds.width - 80, 520)
        let size = l.sizeThatFits(CGSize(width: limit, height: 200))
        l.frame = CGRect(x: (window.bounds.width - size.width) / 2,
                         y: window.bounds.height - size.height - 34, width: size.width, height: size.height)
        l.alpha = 0
        l.isUserInteractionEnabled = false
        window.addSubview(l)
        toastView = l
        UIView.animate(withDuration: 0.2) { l.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak l] in
            UIView.animate(withDuration: 0.3, animations: { l?.alpha = 0 }, completion: { _ in l?.removeFromSuperview() })
        }
    }

    // MARK: dialogs

    static func message(_ vc: UIViewController, title: String, message: String? = nil, ok: String = "OK",
                        action: (() -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ok, style: .default) { _ in action?() })
        vc.present(alert, animated: true)
    }

    static func confirm(_ vc: UIViewController, title: String, message: String? = nil, ok: String,
                        cancel: String = "Cancel", action: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: ok, style: .default) { _ in action() })
        vc.present(alert, animated: true)
    }

    /// Three-way question used for "save changes?" prompts.
    static func ask(_ vc: UIViewController, title: String, yes: String, no: String, cancel: String,
                    onYes: @escaping () -> Void, onNo: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: yes, style: .default) { _ in onYes() })
        alert.addAction(UIAlertAction(title: no, style: .destructive) { _ in onNo() })
        alert.addAction(UIAlertAction(title: cancel, style: .cancel))
        vc.present(alert, animated: true)
    }

    static func input(_ vc: UIViewController, title: String, text: String = "", placeholder: String = "",
                      ok: String = "Save", action: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.placeholder = placeholder
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: ok, style: .default) { [weak alert] _ in
            action(alert?.textFields?.first?.text ?? "")
        })
        vc.present(alert, animated: true)
    }

    /// A themed list dialog; `selected` marks the current single choice.
    @discardableResult
    static func choose(_ vc: UIViewController, title: String, items: [String], selected: Int? = nil,
                       cancel: String = "Cancel", cancelAction: (() -> Void)? = nil,
                       onClose: (() -> Void)? = nil, action: @escaping (Int) -> Void) -> PickerViewController {
        let picker = PickerViewController()
        picker.heading = title
        picker.rows = items
        picker.selected = selected
        picker.buttons = [(cancel, cancelAction)]
        picker.onPick = action
        picker.onClose = onClose
        vc.present(picker, animated: true)
        return picker
    }
}

func unwrap<T>(_ value: T?) -> T? { return value }

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - insets.left - insets.right, height: size.height))
        return CGSize(width: inner.width + insets.left + insets.right, height: inner.height + insets.top + insets.bottom)
    }
}

/// Top-left to bottom-right page backdrop.
final class GradientView: UIView {
    override class var layerClass: AnyClass { return CAGradientLayer.self }
    func set(_ colours: [UIColor], diagonal: Bool = true) {
        guard let g = layer as? CAGradientLayer else { return }
        g.colors = colours.map { $0.cgColor }
        g.startPoint = diagonal ? CGPoint(x: 0, y: 0) : CGPoint(x: 0.5, y: 0)
        g.endPoint = diagonal ? CGPoint(x: 1, y: 1) : CGPoint(x: 0.5, y: 1)
    }
    func backdrop() { set([Ui.bg, Ui.end]) }
}

/// A container whose children are placed by a closure, so each screen states its own geometry.
final class Pane: UIView {
    var onLayout: ((Pane) -> Void)?
    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
        lastSize = bounds.size
    }
    func removeAllSubviews() { subviews.forEach { $0.removeFromSuperview() } }
}

/// The standard panel button: pressed and selected states mirror the Android focus drawable.
final class LMButton: UIButton {
    var action: (() -> Void)?
    var longAction: (() -> Void)? { didSet { installLongPress() } }
    var plain = false { didSet { refresh() } }
    var fillOverride: UIColor? { didSet { refresh() } }
    var whiteText = false { didSet { refresh() } }
    private var longPress: UILongPressGestureRecognizer?

    init(_ title: String, size: CGFloat = 14, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.action = action
        setTitle(title, for: .normal)
        titleLabel?.font = Ui.font(size)
        titleLabel?.numberOfLines = 2
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.7
        titleLabel?.textAlignment = .center
        contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        layer.cornerRadius = 2
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isExclusiveTouch = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var title: String {
        get { return title(for: .normal) ?? "" }
        set { setTitle(newValue, for: .normal); accessibilityLabel = newValue }
    }

    func alignLeft() {
        contentHorizontalAlignment = .left
        titleLabel?.textAlignment = .left
    }

    override var isHighlighted: Bool { didSet { refresh() } }
    override var isSelected: Bool { didSet { refresh() } }
    override var isEnabled: Bool { didSet { refresh() } }

    func refresh() {
        let colour: UIColor = whiteText ? .white : Ui.text
        setTitleColor(colour, for: .normal)
        setTitleColor(colour, for: .highlighted)
        setTitleColor(colour, for: .selected)
        setTitleColor(colour.withAlphaComponent(0.44), for: .disabled)
        if plain {
            backgroundColor = .clear
            layer.borderWidth = isHighlighted ? 1 : 0
            layer.borderColor = UIColor.white.cgColor
            return
        }
        if isHighlighted {
            backgroundColor = fillOverride ?? Ui.focus
            layer.borderWidth = 1
            layer.borderColor = Ui.text.cgColor
        } else if isSelected {
            backgroundColor = fillOverride ?? Ui.active
            layer.borderWidth = 1
            layer.borderColor = Ui.activeStroke.cgColor
        } else {
            backgroundColor = fillOverride ?? Ui.panel
            layer.borderWidth = 0
        }
    }

    @objc private func tapped() { action?() }

    private func installLongPress() {
        if longAction == nil || longPress != nil { return }
        let g = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        addGestureRecognizer(g)
        longPress = g
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        if g.state == .began { cancelTracking(with: nil); isHighlighted = false; longAction?() }
    }
}

// MARK: - List dialog

/// One themed dialog for menus, single choice, multiple choice and searchable lists.
final class PickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    var heading = ""
    var note: String?
    var rows: [String] = []
    var selected: Int?
    var checked: Set<Int>?
    var searchable = false
    var searchPlaceholder = "Search"
    var buttons: [(String, (() -> Void)?)] = []
    var onPick: ((Int) -> Void)?
    var onToggle: ((Int, Bool) -> Void)?
    var onClose: (() -> Void)?

    private let panel = UIView()
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let search = Ui.field("Search")
    private let table = UITableView(frame: .zero, style: .plain)
    private var buttonViews: [LMButton] = []
    private var shown: [Int] = []
    private var finished = false

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(outside(_:)))
        dismissTap.cancelsTouchesInView = false
        view.addGestureRecognizer(dismissTap)

        panel.backgroundColor = Ui.bg
        panel.layer.cornerRadius = 4
        panel.layer.borderWidth = 1
        panel.layer.borderColor = Ui.text.withAlphaComponent(0.35).cgColor
        panel.clipsToBounds = true
        view.addSubview(panel)

        titleLabel.text = heading
        titleLabel.font = Ui.font(18, bold: true)
        titleLabel.textColor = Ui.text
        titleLabel.numberOfLines = 2
        panel.addSubview(titleLabel)

        noteLabel.text = note
        noteLabel.font = Ui.font(13)
        noteLabel.textColor = Ui.muted
        noteLabel.numberOfLines = 0
        panel.addSubview(noteLabel)

        search.placeholder = searchPlaceholder
        search.delegate = self
        search.addTarget(self, action: #selector(filter), for: .editingChanged)
        search.isHidden = !searchable
        panel.addSubview(search)

        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.rowHeight = 46
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        panel.addSubview(table)

        for (n, entry) in buttons.enumerated() {
            let b = LMButton(entry.0) { [weak self] in self?.finish(entry.1) }
            b.tag = n
            panel.addSubview(b)
            buttonViews.append(b)
        }
        shown = Array(rows.indices)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets)
        let width = min(470, safe.width - 24)
        let pad: CGFloat = 14
        let inner = width - pad * 2
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: inner, height: 60)).height
        let noteHeight = (note ?? "").isEmpty ? 0 : min(120, noteLabel.sizeThatFits(CGSize(width: inner, height: 400)).height + 8)
        let searchHeight: CGFloat = searchable ? 44 + 6 : 0
        let buttonHeight: CGFloat = buttonViews.isEmpty ? 0 : 44 + 8
        let chrome = pad + titleHeight + 8 + noteHeight + searchHeight + buttonHeight + pad
        let limit = safe.height - 16
        let wanted = CGFloat(rows.count) * 46
        let tableHeight = max(46, min(wanted, limit - chrome))
        let height = min(limit, chrome + (rows.isEmpty ? 0 : tableHeight))
        panel.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        var y = pad
        titleLabel.frame = CGRect(x: pad, y: y, width: inner, height: titleHeight); y += titleHeight + 8
        noteLabel.frame = CGRect(x: pad, y: y, width: inner, height: max(0, noteHeight - 8)); y += noteHeight
        if searchable { search.frame = CGRect(x: pad, y: y, width: inner, height: 44); y += 50 }
        let bottom = height - pad - buttonHeight
        table.frame = CGRect(x: pad, y: y, width: inner, height: max(0, bottom - y))
        if !buttonViews.isEmpty {
            let each = (inner - CGFloat(buttonViews.count - 1) * Ui.gap) / CGFloat(buttonViews.count)
            for (n, b) in buttonViews.enumerated() {
                b.frame = CGRect(x: pad + CGFloat(n) * (each + Ui.gap), y: height - pad - 44, width: each, height: 44)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let s = selected, let at = shown.firstIndex(of: s) {
            table.scrollToRow(at: IndexPath(row: at, section: 0), at: .middle, animated: false)
        }
    }

    @objc private func outside(_ g: UITapGestureRecognizer) {
        if !panel.frame.contains(g.location(in: view)) { finish(nil) }
    }

    @objc private func filter() {
        let q = (search.text ?? "").lowercased()
        shown = rows.indices.filter { q.isEmpty || rows[$0].lowercased().contains(q) }
        table.reloadData()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool { textField.resignFirstResponder(); return true }

    private func finish(_ then: (() -> Void)?) {
        if finished { return }
        finished = true
        let close = onClose
        dismiss(animated: true) { then?(); close?() }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return shown.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let index = shown[indexPath.row]
        var prefix = ""
        if let checked = checked { prefix = checked.contains(index) ? "☑  " : "☐  " }
        else if selected != nil { prefix = selected == index ? "●  " : "○  " }
        cell.textLabel?.text = prefix + rows[index]
        cell.textLabel?.font = Ui.font(16)
        cell.textLabel?.textColor = Ui.text
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.adjustsFontSizeToFitWidth = true
        cell.textLabel?.minimumScaleFactor = 0.75
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = Ui.panel
        let highlight = UIView()
        highlight.backgroundColor = Ui.focus
        cell.selectedBackgroundView = highlight
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let index = shown[indexPath.row]
        if checked != nil {
            let on = !(checked?.contains(index) ?? false)
            if on { checked?.insert(index) } else { checked?.remove(index) }
            onToggle?(index, on)
            tableView.reloadRows(at: [indexPath], with: .none)
            return
        }
        let pick = onPick
        finish { pick?(index) }
    }
}

// MARK: - Screens

/// Landscape, full-screen base for every screen.
class BaseViewController: UIViewController {
    let backdrop = GradientView()
    private(set) var appliedTheme = ""

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }
    /// Menus allow the screensaver; players and transfers do not.
    var idleAllowed: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        Ui.load()
        appliedTheme = Ui.themeKey
        backdrop.backdrop()
        backdrop.frame = view.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(backdrop)
    }

    func markThemeApplied() { appliedTheme = Ui.themeKey; backdrop.backdrop() }

    /// The usable page area: inside the notch on both sides, with the Android phone padding.
    var pageRect: CGRect {
        let s = view.safeAreaInsets
        let side = max(8, max(s.left, s.right) - 6)
        let bottom = max(6, s.bottom - 10)
        return CGRect(x: side, y: 6, width: view.bounds.width - side * 2, height: view.bounds.height - 6 - bottom)
    }

    func close() {
        if let nav = navigationController, nav.viewControllers.count > 1 { nav.popViewController(animated: false) }
        else { dismiss(animated: true) }
    }

    func open(_ vc: UIViewController) { navigationController?.pushViewController(vc, animated: false) }
}

/// Settings-style page: logo, title, Back, then free content.
class PageViewController: BaseViewController {
    let brand = BrandView()
    let titleLabel = Ui.label("", 22, nil, lines: 1)
    let backButton = LMButton("‹ Back")
    let statusLabel = Ui.label("", 13, nil, lines: 2)
    let content = Pane()
    var pageTitle: String { return "" }
    var pageSubtitle: String { return "" }
    var showsBack: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        titleLabel.text = pageTitle
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.65
        statusLabel.text = pageSubtitle
        statusLabel.textColor = Ui.muted
        backButton.action = { [weak self] in self?.backPressed() }
        backButton.isHidden = !showsBack
        let viewGroup1: [UIView] = [brand, titleLabel, backButton, statusLabel, content]
        viewGroup1.forEach { view.addSubview($0) }
    }

    func backPressed() { close() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let r = pageRect
        brand.frame = CGRect(x: r.minX, y: r.minY, width: 96, height: Ui.header)
        let backWidth: CGFloat = showsBack ? 84 : 0
        titleLabel.frame = CGRect(x: brand.frame.maxX + 12, y: r.minY, width: r.width - 96 - 20 - backWidth, height: Ui.header)
        backButton.frame = CGRect(x: r.maxX - 84, y: r.minY + 5, width: 84, height: 34)
        let statusHeight: CGFloat = (statusLabel.text ?? "").isEmpty ? 0 : 34
        statusLabel.frame = CGRect(x: r.minX, y: r.minY + Ui.header, width: r.width, height: statusHeight)
        content.frame = CGRect(x: r.minX, y: statusLabel.frame.maxY + 2, width: r.width, height: r.maxY - statusLabel.frame.maxY - 2)
    }
}
