import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Ui.load()
        DownloadManager.shared.start()
        let window = TouchWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = UIColor(argb: 0xff040b16)
        window.overrideUserInterfaceStyle = .dark
        let splash = SplashViewController()
        splash.onFinished = { [weak self] in self?.showMain() }
        window.rootViewController = splash
        window.makeKeyAndVisible()
        self.window = window
        Ui.window = window
        return true
    }

    private func showMain() {
        guard let window = window else { return }
        let navigation = LandscapeNavigationController(rootViewController: MainViewController())
        navigation.setNavigationBarHidden(true, animated: false)
        window.rootViewController = navigation
        UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve, animations: nil)
        IdleMonitor.shared.reset()
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .landscape
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Prefs.flushAll()
        IdleMonitor.shared.suspend()
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.identifier else { completionHandler(); return }
        DownloadManager.shared.backgroundCompletion = completionHandler
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        IdleMonitor.shared.reset()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        PlaybackSession.shared.save()
        Prefs.flushAll()
    }
}

final class LandscapeNavigationController: UINavigationController {
    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }
    override var childForStatusBarHidden: UIViewController? { return topViewController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { return topViewController }
}

/// Every touch counts as activity for the screensaver timer.
final class TouchWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches { IdleMonitor.shared.reset() }
        super.sendEvent(event)
    }
}

/// Menu-only idle timer. Players deliberately opt out through `idleAllowed`.
final class IdleMonitor {
    static let shared = IdleMonitor()
    private var timer: Timer?
    private weak var saver: ScreensaverViewController?

    private init() {}

    func suspend() {
        timer?.invalidate()
        timer = nil
    }

    func reset() {
        timer?.invalidate()
        timer = nil
        let delay = ScreensaverSettingsViewController.delay()
        if delay <= 0 || saver != nil { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.fire() }
    }

    private func current() -> UIViewController? {
        var vc = Ui.top()
        if let nav = vc as? UINavigationController { vc = nav.topViewController }
        return vc
    }

    private func fire() {
        guard let vc = current() as? BaseViewController, vc.idleAllowed else { reset(); return }
        showScreensaver()
    }

    func showScreensaver() {
        guard saver == nil, let host = Ui.top(), !(host is ScreensaverViewController) else { return }
        timer?.invalidate()
        timer = nil
        let created = ScreensaverViewController()
        created.onDismissed = { [weak self] in self?.reset() }
        saver = created
        host.present(created, animated: true)
    }
}

// MARK: - Opening ident

/// Brief, silent ident on launch. Tap to skip.
final class SplashViewController: UIViewController {
    var onFinished: (() -> Void)?
    private var finished = false
    private let ident = IdentView()

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(argb: 0xff040b16)
        ident.frame = view.bounds
        ident.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(ident)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(finish)))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ident.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.finish() }
    }

    @objc private func finish() {
        if finished { return }
        finished = true
        ident.stop()
        onFinished?()
    }
}

final class IdentView: UIView {
    private var link: CADisplayLink?
    private var started = CACurrentMediaTime()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = UIColor(argb: 0xff040b16)
        contentMode = .redraw
        accessibilityLabel = "Light Media opening ident"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start() {
        started = CACurrentMediaTime()
        link?.invalidate()
        let created = CADisplayLink(target: self, selector: #selector(step))
        created.add(to: .main, forMode: .common)
        link = created
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        setNeedsDisplay()
        if CACurrentMediaTime() - started > 2.3 { stop() }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height
        let time = CGFloat(min(1, (CACurrentMediaTime() - started) / 2.2))
        let press = sin(.pi * max(0, min(1, (time - 0.08) / 0.22)))
        var reveal = max(0, min(1, (time - 0.22) / 0.56))
        reveal = reveal * reveal * (3 - 2 * reveal)
        UIColor(argb: 0xff040b16).setFill()
        ctx.fill(bounds)
        let radius = max(1, w * (0.04 + 0.75 * reveal))
        let glow = [UIColor(red: 40 / 255, green: 145 / 255, blue: 245 / 255, alpha: 65 / 255 * reveal).cgColor,
                    UIColor(argb: 0x001b6fc0).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow, locations: nil) {
            let centre = CGPoint(x: w * 0.36, y: h * 0.32)
            ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
        }
        let area = CGRect(x: w * 0.29, y: h * 0.18, width: w * 0.42, height: h * 0.64)
        BrandView.drawLogo(ctx, area, light: reveal, press: press)
    }
}

// MARK: - Screensaver

/// Dimmed logo and clock, drifting slowly. Any touch returns to the menu.
final class ScreensaverViewController: UIViewController {
    var onDismissed: (() -> Void)?
    private let scene = ScreensaverScene()
    private var closing = false

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(argb: 0xff03070d)
        scene.frame = view.bounds
        scene.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scene)
        view.accessibilityLabel = "Light Media screensaver. Touch the screen to return."
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scene.start()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if closing { return }
        closing = true
        scene.stop()
        let done = onDismissed
        dismiss(animated: true) { done?() }
    }
}

final class ScreensaverScene: UIView {
    private var link: CADisplayLink?
    private let started = CACurrentMediaTime()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = UIColor(argb: 0xff03070d)
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func start() {
        link?.invalidate()
        let created = CADisplayLink(target: self, selector: #selector(step))
        created.preferredFramesPerSecond = 30
        created.add(to: .main, forMode: .common)
        link = created
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() { setNeedsDisplay() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width, h = bounds.height
        let t = CGFloat(CACurrentMediaTime() - started)
        UIColor(argb: 0xff03070d).setFill()
        ctx.fill(bounds)
        let x = w * (0.5 + 0.14 * sin(t / 9))
        let y = h * (0.45 + 0.12 * sin(t / 13))
        ctx.saveGState()
        ctx.setAlpha(165.0 / 255.0)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        BrandView.drawLogo(ctx, CGRect(x: x - w * 0.22, y: y - h * 0.16, width: w * 0.44, height: h * 0.28), light: 1, press: 0)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        let font = UIFont.systemFont(ofSize: 22, weight: .light)
        let text = Epg.clock.string(from: Date()) as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.lightGray]
        let size = text.size(withAttributes: attributes)
        // Anchor to the visible "media" baseline (188 in the 210-high artwork).
        let logoScale = min(w * 0.44 / 280, h * 0.28 / 210)
        let logoBottom = y - h * 0.02 + (188 - 105) * logoScale
        text.draw(at: CGPoint(x: x - size.width / 2, y: logoBottom + 10), withAttributes: attributes)
    }
}
