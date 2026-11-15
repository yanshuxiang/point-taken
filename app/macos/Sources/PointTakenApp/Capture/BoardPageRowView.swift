import AppKit

/// One page in the review window's sidebar:
///
///     [thumbnail]  第 2 页  1 个未说明             [✓]
///                  0:21–0:47 · 2 个标记
///
/// The checkbox says whether the page goes to the AI. "未说明" (orange) counts marks with no note and nothing said
/// near them — the ones the AI would only see as numbers.
final class BoardPageRowView: NSTableCellView {
    let check = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let thumb = NSImageView()
    private let title = BoardStyle.label("", .body, .medium)
    private let detail = NSTextField(labelWithString: "")
    private let warn = BoardStyle.label("", .subheadline, .medium, color: .systemOrange)

    override init(frame: NSRect) {
        super.init(frame: frame)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = BoardStyle.thumbRadius
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderWidth = 1
        thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.usesSingleLineMode = true
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        check.setContentHuggingPriority(.required, for: .horizontal)
        warn.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        for v in [thumb, title, warn, detail, check] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BoardStyle.tight),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 72),
            thumb.heightAnchor.constraint(equalToConstant: 45),
            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: BoardStyle.group - 2),
            warn.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: BoardStyle.inner - 2),
            warn.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            warn.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -BoardStyle.tight),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -BoardStyle.tight),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -BoardStyle.tight),
            check.widthAnchor.constraint(equalToConstant: BoardStyle.hit),
            check.heightAnchor.constraint(equalToConstant: BoardStyle.hit),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    /// Selected with emphasis (a strong highlight), the words turn light; otherwise their normal colours.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let strong = backgroundStyle == .emphasized
            title.textColor = strong ? .alternateSelectedControlTextColor : .labelColor
            detail.textColor = strong ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        }
    }

    func show(number: Int, thumb image: CGImage?, time: String, marks: Int, unexplained: Int, included: Bool) {
        thumb.image = image.map { NSImage(cgImage: $0, size: .zero) }
        effectiveAppearance.performAsCurrentDrawingAppearance { thumb.layer?.borderColor = NSColor.separatorColor.cgColor }
        title.stringValue = "第 \(number) 页"
        // the sidebar shows the span only (first to last); the header above the picture gives the stretches
        let span = time.replacingOccurrences(of: #"（\d+ 段）"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " – ", with: "–")
        detail.font = BoardStyle.digits(.subheadline)
        detail.textColor = backgroundStyle == .emphasized
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        detail.stringValue = [span.isEmpty ? "没有时间记录" : span, marks > 0 ? "\(marks) 个标记" : "没有标记"].joined(separator: " · ")
        warn.stringValue = unexplained > 0 ? "\(unexplained) 个未说明" : ""
        warn.isHidden = unexplained == 0
        warn.toolTip = "有 \(unexplained) 个标记既没写说明、附近也没说话"
        check.state = included ? .on : .off
        check.toolTip = included ? "这一页会交给 AI（点一下取消）" : "这一页不交给 AI（点一下勾上）"
        check.setAccessibilityLabel("第 \(number) 页交给 AI")
    }
}

/// A page row's selection: a soft rounded highlight (the current system's sidebar shape), the row's text keeping its
/// normal colours so it stays readable light or dark, focused or not.
final class BoardPageSelectionRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isSelected: Bool { didSet { needsDisplay = true } }
    override var isEmphasized: Bool { didSet { needsDisplay = true } }
    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: BoardStyle.inner + 2, dy: 1)
        NSColor.labelColor.withAlphaComponent(isEmphasized ? 0.10 : 0.07).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
    }
}
