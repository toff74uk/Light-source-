import UIKit
import ImageIO

/// A small canvas wrapper so the Android pictogram coordinates port one-to-one.
final class Pen {
    let ctx: CGContext
    var colour: UIColor
    var fill = false
    var width: CGFloat = 3

    init(_ ctx: CGContext, _ colour: UIColor) {
        self.ctx = ctx
        self.colour = colour
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
    }

    private func paint(_ path: UIBezierPath) {
        if fill {
            colour.setFill()
            path.fill()
        } else {
            colour.setStroke()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: x1, y: y1))
        p.addLine(to: CGPoint(x: x2, y: y2))
        colour.setStroke()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.stroke()
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        paint(UIBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)))
    }

    func oval(_ l: CGFloat, _ t: CGFloat, _ r: CGFloat, _ b: CGFloat) {
        paint(UIBezierPath(ovalIn: CGRect(x: l, y: t, width: r - l, height: b - t)))
    }

    func rect(_ l: CGFloat, _ t: CGFloat, _ r: CGFloat, _ b: CGFloat) {
        paint(UIBezierPath(rect: CGRect(x: l, y: t, width: r - l, height: b - t)))
    }

    func rrect(_ l: CGFloat, _ t: CGFloat, _ r: CGFloat, _ b: CGFloat, _ radius: CGFloat) {
        paint(UIBezierPath(roundedRect: CGRect(x: l, y: t, width: r - l, height: b - t), cornerRadius: radius))
    }

    /// Android drawArc: degrees clockwise from three o'clock, inside a square box.
    func arc(_ l: CGFloat, _ t: CGFloat, _ r: CGFloat, _ b: CGFloat, _ start: CGFloat, _ sweep: CGFloat) {
        let centre = CGPoint(x: (l + r) / 2, y: (t + b) / 2)
        let p = UIBezierPath(arcCenter: centre, radius: (r - l) / 2, startAngle: start * .pi / 180,
                             endAngle: (start + sweep) * .pi / 180, clockwise: sweep >= 0)
        colour.setStroke()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.stroke()
    }

    func polygon(_ points: [(CGFloat, CGFloat)]) {
        guard let first = points.first else { return }
        let p = UIBezierPath()
        p.move(to: CGPoint(x: first.0, y: first.1))
        for pt in points.dropFirst() { p.addLine(to: CGPoint(x: pt.0, y: pt.1)) }
        p.close()
        paint(p)
    }

    func rotate(_ degrees: CGFloat, _ px: CGFloat, _ py: CGFloat) {
        ctx.translateBy(x: px, y: py)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.translateBy(x: -px, y: -py)
    }
}

/// Resolution-independent pictograms, shared by menu tiles and playback controls.
enum Icons {
    @discardableResult
    static func draw(_ ctx: CGContext, _ colour: UIColor, _ name: String, x: CGFloat, y: CGFloat, size: CGFloat) -> Bool {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: size / 48, y: size / 48)
        let p = Pen(ctx, colour)
        switch name {
        case "tv":
            p.rrect(4, 6, 44, 34, 2); p.line(24, 34, 24, 42); p.line(15, 42, 33, 42)
        case "film":
            p.circle(24, 24, 19)
            for _ in 0..<4 { p.circle(24, 13, 4); p.rotate(90, 24, 24) }
            p.circle(24, 24, 2)
        case "series":
            p.rrect(5, 15, 43, 41, 2); p.rect(5, 6, 43, 15)
            p.line(16, 6, 11, 15); p.line(29, 6, 24, 15); p.line(41, 6, 36, 15)
        case "apps":
            for row in 0..<3 { for col in 0..<3 { p.circle(CGFloat(10 + col * 14), CGFloat(10 + row * 14), 3) } }
        case "folder":
            p.polygon([(5, 13), (5, 39), (43, 39), (43, 16), (24, 16), (19, 10), (5, 10)])
        case "profile":
            p.fill = true
            p.circle(24, 11, 6); p.circle(9, 18, 5); p.circle(39, 18, 5)
            p.rrect(16, 21, 32, 44, 7); p.rrect(2, 27, 14, 44, 5); p.rrect(34, 27, 46, 44, 5)
        case "appearance":
            p.rrect(3, 4, 45, 35, 3); p.line(24, 35, 24, 44); p.line(14, 44, 34, 44); p.circle(24, 19, 6)
            for _ in 0..<8 { p.line(24, 7, 24, 9); p.rotate(45, 24, 19) }
        case "search":
            p.circle(20, 20, 14); p.line(30, 30, 44, 44)
        case "moon":
            let moon = UIBezierPath()
            moon.move(to: CGPoint(x: 27, y: 4))
            moon.addCurve(to: CGPoint(x: 28, y: 43), controlPoint1: CGPoint(x: 0, y: 6), controlPoint2: CGPoint(x: 0, y: 42))
            moon.addCurve(to: CGPoint(x: 44, y: 31), controlPoint1: CGPoint(x: 35, y: 43), controlPoint2: CGPoint(x: 42, y: 38))
            moon.addCurve(to: CGPoint(x: 27, y: 4), controlPoint1: CGPoint(x: 22, y: 39), controlPoint2: CGPoint(x: 12, y: 17))
            moon.close()
            colour.setFill()
            moon.fill()
        case "list":
            for i in 0..<3 {
                let yy = CGFloat(12 + i * 12)
                p.rect(5, yy - 2, 9, yy + 2); p.line(17, yy, 43, yy)
            }
        case "controller":
            p.rrect(4, 12, 44, 36, 9); p.line(11, 24, 23, 24); p.line(17, 18, 17, 30)
            p.circle(32, 20, 1.5); p.circle(37, 27, 1.5)
        case "clock":
            p.circle(24, 24, 18); p.line(24, 11, 24, 24); p.line(24, 24, 33, 28)
        case "speed":
            p.arc(5, 7, 43, 45, 180, 180); p.line(24, 29, 35, 15); p.circle(24, 29, 3)
            p.line(5, 29, 5, 36); p.line(43, 29, 43, 36)
        case "download", "import", "export":
            let up = name == "export"
            p.line(24, up ? 31 : 7, 24, up ? 7 : 31)
            p.line(15, up ? 16 : 22, 24, up ? 7 : 31)
            p.line(33, up ? 16 : 22, 24, up ? 7 : 31)
            p.line(7, 32, 7, 41); p.line(7, 41, 41, 41); p.line(41, 41, 41, 32)
        case "refresh":
            p.arc(7, 7, 41, 41, 210, 145); p.arc(7, 7, 41, 41, 30, 145)
            p.line(41, 7, 41, 21); p.line(28, 21, 41, 21); p.line(7, 27, 7, 41); p.line(7, 27, 20, 27)
        case "trash":
            p.line(7, 12, 41, 12); p.rect(18, 5, 30, 12); p.rrect(12, 12, 36, 43, 2)
            p.line(20, 20, 20, 35); p.line(28, 20, 28, 35)
        case "music":
            p.line(19, 9, 19, 34); p.line(19, 9, 38, 6); p.line(38, 6, 38, 30)
            p.oval(6, 29, 19, 39); p.oval(25, 25, 38, 35)
        case "play":
            p.polygon([(14, 7), (39, 24), (14, 41)])
        case "pause":
            p.fill = true
            p.rrect(13, 8, 20, 40, 1); p.rrect(28, 8, 35, 40, 1)
        case "previous", "next":
            if name == "previous" { ctx.translateBy(x: 48, y: 0); ctx.scaleBy(x: -1, y: 1) }
            p.polygon([(10, 9), (33, 24), (10, 39)]); p.line(38, 9, 38, 39)
        case "last-channel":
            p.arc(9, 10, 41, 42, -100, 280); p.line(23, 10, 14, 4); p.line(23, 10, 15, 17)
        case "server":
            p.rrect(7, 5, 41, 20, 3); p.rrect(7, 28, 41, 43, 3); p.circle(14, 12, 1); p.circle(14, 35, 1)
            p.line(23, 12, 34, 12); p.line(23, 35, 34, 35)
        case "settings":
            p.circle(24, 24, 12); p.circle(24, 24, 4)
            for _ in 0..<8 { p.line(24, 5, 24, 10); p.rotate(45, 24, 24) }
        default:
            return false
        }
        return true
    }

    /// Dark rounded badge behind a pictogram, as used on tiles and poster placeholders.
    static func badge(_ ctx: CGContext, _ glyph: String, x: CGFloat, y: CGFloat, size: CGFloat) {
        let rect = CGRect(x: x, y: y, width: size, height: size)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: size * 0.19)
        ctx.saveGState()
        path.addClip()
        let colours = [UIColor(argb: 0xff102c48).cgColor, UIColor(argb: 0xff071a30).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: nil) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: x, y: y), end: CGPoint(x: x, y: y + size), options: [])
        }
        ctx.restoreGState()
        UIColor(argb: 0xff48708c).setStroke()
        let border = UIBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: size * 0.19)
        border.lineWidth = max(1, size * 0.018)
        border.stroke()
        if glyph == "logo" {
            BrandView.drawLogo(ctx, CGRect(x: x + 4, y: y + 4, width: size - 8, height: size - 8), light: 1, press: 0)
        } else {
            draw(ctx, UIColor(argb: 0xffe3f1ff), glyph, x: x + size * 0.16, y: y + size * 0.16, size: size * 0.68)
        }
    }
}

/// Transparent, resolution-independent Light Media wordmark.
final class BrandView: UIView {
    var logoAlpha: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Light Media"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        BrandView.drawLogo(ctx, bounds, light: 1, press: 0)
    }

    private static func text(_ s: String, _ x: CGFloat, _ baseline: CGFloat, _ font: UIFont, _ colour: UIColor) {
        (s as NSString).draw(at: CGPoint(x: x, y: baseline - font.ascender),
                             withAttributes: [.font: font, .foregroundColor: colour])
    }

    private static func mix(_ from: CGFloat, _ span: CGFloat, _ light: CGFloat) -> CGFloat { return (from + span * light) / 255 }

    static func drawLogo(_ ctx: CGContext, _ d: CGRect, light: CGFloat, press: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let scale = min(d.width / 280, d.height / 210)
        ctx.translateBy(x: d.midX - 140 * scale, y: d.midY - 105 * scale)
        ctx.scaleBy(x: scale, y: scale)

        let big = UIFont.systemFont(ofSize: 104, weight: .black)
        let lightColour = UIColor(red: mix(29, 211, light), green: mix(40, 207, light), blue: mix(56, 199, light), alpha: 1)
        // Draw the i stem separately so its only dot is the play button.
        text("l", 18, 112, big, lightColour)
        let x = 18 + ("l" as NSString).size(withAttributes: [.font: big]).width
        lightColour.setFill()
        UIBezierPath(roundedRect: CGRect(x: x + 5, y: 56, width: 17, height: 56), cornerRadius: 3).fill()
        text("ght", x + 27, 112, big, lightColour)

        let bx = x + 13.5, by = 32 + press * 4
        ctx.saveGState()
        let shrink = 1 - 0.12 * press
        ctx.translateBy(x: bx, y: by); ctx.scaleBy(x: shrink, y: shrink); ctx.translateBy(x: -bx, y: -by)
        UIColor(argb: 0xff10354d).setFill()
        UIBezierPath(roundedRect: CGRect(x: bx - 15, y: by - 16, width: 30, height: 32), cornerRadius: 7).fill()
        ctx.saveGState()
        UIBezierPath(roundedRect: CGRect(x: bx - 14, y: by - 15, width: 28, height: 28), cornerRadius: 6).addClip()
        let colours = [UIColor(argb: 0xffa6edff).cgColor, UIColor(argb: 0xff369cd3).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: nil) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: bx, y: by - 14), end: CGPoint(x: bx, y: by + 14), options: [])
        }
        ctx.restoreGState()
        UIColor(argb: 0xff082638).setFill()
        let play = UIBezierPath()
        play.move(to: CGPoint(x: bx - 4, y: by - 8))
        play.addLine(to: CGPoint(x: bx + 7, y: by - 1))
        play.addLine(to: CGPoint(x: bx - 4, y: by + 6))
        play.close()
        play.fill()
        ctx.restoreGState()

        let small = UIFont.systemFont(ofSize: 70, weight: .black)
        let mediaColour = UIColor(red: mix(17, 111, light), green: mix(34, 186, light), blue: mix(52, 203, light), alpha: 1)
        let mediaWidth = ("media" as NSString).size(withAttributes: [.font: small]).width
        ctx.saveGState()
        if mediaWidth > 240 {
            ctx.translateBy(x: 20, y: 0); ctx.scaleBy(x: 240 / mediaWidth, y: 1); ctx.translateBy(x: -20, y: 0)
        }
        text("media", 20, 188, small, mediaColour)
        ctx.restoreGState()
    }
}

/// Poster or channel artwork, with a generated placeholder until an image arrives.
final class ArtView: UIView {
    private var titleSeed: Int = 0
    private var image: UIImage?
    var fit = true { didSet { setNeedsDisplay() } }
    var squarePlaceholder = false { didSet { setNeedsDisplay() } }
    var alignStart = false { didSet { setNeedsDisplay() } }
    var tagKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        clipsToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func bind(_ name: String, _ picture: UIImage?) {
        titleSeed = Int(name.javaHash)
        image = picture
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        var w = bounds.width, h = bounds.height
        if w <= 0 || h <= 0 { return }
        if let image = image, image.size.width > 0, image.size.height > 0 {
            if fit && !alignStart { Ui.bg.setFill(); ctx.fill(bounds) }
            let scale = fit ? min(w / image.size.width, h / image.size.height) : max(w / image.size.width, h / image.size.height)
            let iw = image.size.width * scale, ih = image.size.height * scale
            var target = CGRect(x: (w - iw) / 2, y: (h - ih) / 2, width: iw, height: ih)
            if alignStart { target.origin = .zero }
            image.draw(in: target)
            return
        }
        ctx.saveGState()
        if squarePlaceholder {
            Ui.bg.setFill(); ctx.fill(bounds)
            let side = min(w, h)
            ctx.translateBy(x: (w - side) / 2, y: (h - side) / 2)
            w = side; h = side
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let base = UIColor(argb: Theme.colour(h: Double(190 + floorMod(titleSeed, 130)), s: 0.68, v: 0.38))
        let colours = [UIColor(argb: 0xff041329).cgColor, base.cgColor, UIColor(argb: 0xff2c83a5).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: nil) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        UIColor(argb: 0x237adaff).setFill()
        ctx.fillEllipse(in: CGRect(x: w * 0.82 - h * 0.8, y: h * 0.13 - h * 0.8, width: h * 1.6, height: h * 1.6))
        UIColor(argb: 0x257adaff).setFill()
        ctx.fillEllipse(in: CGRect(x: w * 0.82 - h * 0.56, y: h * 0.13 - h * 0.56, width: h * 1.12, height: h * 1.12))
        let side = min(w, h)
        Icons.badge(ctx, squarePlaceholder ? "logo" : "film", x: w / 2 - side * 0.28, y: h / 2 - side * 0.28, size: side * 0.56)
        ctx.restoreGState()
    }
}

/// Badge-only view used on settings tiles.
final class GlyphView: UIView {
    let glyph: String

    init(_ glyph: String) {
        self.glyph = glyph
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let size = min(bounds.width, bounds.height)
        Icons.badge(ctx, glyph, x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, size: size)
    }
}

/// Theme-independent check shape: an outline for hidden and a contrasting tick for shown.
final class CheckView: UIView {
    var checked = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.scaleBy(x: bounds.width / 28, y: bounds.height / 28)
        let box = UIBezierPath(roundedRect: CGRect(x: 3, y: 3, width: 22, height: 22), cornerRadius: 3)
        if checked {
            Ui.text.setFill(); box.fill()
            (Ui.palette.black ? UIColor.white : UIColor.black).setStroke()
            let tick = UIBezierPath()
            tick.move(to: CGPoint(x: 8, y: 14)); tick.addLine(to: CGPoint(x: 12, y: 18)); tick.addLine(to: CGPoint(x: 20, y: 9))
            tick.lineWidth = 3; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
            tick.stroke()
        } else {
            Ui.text.setStroke(); box.lineWidth = 2; box.stroke()
        }
        ctx.restoreGState()
    }
}

/// Icon-only video control with a full touch target and a spoken action label.
final class IconButton: UIControl {
    private var icon: String
    private let iconSize: CGFloat
    var action: (() -> Void)?

    init(label: String, icon: String, size: CGFloat, action: @escaping () -> Void) {
        self.icon = icon
        self.iconSize = size
        self.action = action
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = label
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setAction(_ label: String, _ name: String) {
        icon = name
        accessibilityLabel = label
        setNeedsDisplay()
    }

    override var isHighlighted: Bool { didSet { setNeedsDisplay() } }
    override var isEnabled: Bool { didSet { setNeedsDisplay() } }

    @objc private func tapped() { action?() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let colour = isEnabled ? UIColor.white : UIColor(argb: 0x70ffffff)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor(argb: 0xdd000000).cgColor)
        if isHighlighted {
            colour.setStroke()
            let ring = UIBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3))
            ring.lineWidth = 2
            ring.stroke()
        }
        let size = min(iconSize, min(bounds.width, bounds.height) - 12)
        Icons.draw(ctx, colour, icon, x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, size: size)
    }
}

// MARK: - Artwork loading

/// Small, bounded image loader: two at a time, no redirects, nothing larger than 3 MB.
final class Artwork {
    private let cache = NSCache<NSString, UIImage>()
    private let allowHttp: Bool
    private let queue = OperationQueue()
    private var closed = false

    init(allowHttp: Bool) {
        self.allowHttp = allowHttp
        cache.totalCostLimit = 12 * 1024 * 1024
        queue.maxConcurrentOperationCount = 2
    }

    func load(_ view: ArtView, _ item: MediaItem) {
        view.tagKey = item.key
        let cached = cache.object(forKey: item.image as NSString)
        view.bind(item.name, cached)
        if item.image.isEmpty || cached != nil || closed { return }
        guard let url = URL(string: item.image), let scheme = url.scheme?.lowercased(),
              scheme == "https" || (allowHttp && scheme == "http"), url.user == nil else { return }
        let key = item.key, name = item.name, address = item.image
        queue.addOperation { [weak self, weak view] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let wait = DispatchSemaphore(value: 0)
            var payload: Data?
            let task = Http.session.dataTask(with: request) { data, response, _ in
                if let data = data, (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 3 * 1024 * 1024 {
                    payload = data
                }
                wait.signal()
            }
            task.resume()
            _ = wait.wait(timeout: .now() + 8)
            guard let data = payload, let picture = Artwork.downsample(data) else { return }
            self?.cache.setObject(picture, forKey: address as NSString,
                                  cost: Int(picture.size.width * picture.size.height * 4))
            DispatchQueue.main.async {
                if let view = view, view.tagKey == key { view.bind(name, picture) }
            }
        }
    }

    private static func downsample(_ data: Data) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumb: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCacheImmediately: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 640]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumb as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    func close() {
        closed = true
        queue.cancelAllOperations()
        cache.removeAllObjects()
    }
}
