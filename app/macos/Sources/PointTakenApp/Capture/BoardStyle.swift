import AppKit

/// The review window's look in one place, following Apple's Human Interface Guidelines for macOS:
/// - type: the system text styles (title3 15 pt for a page's title, body 13 pt for content, callout 12 pt for
///   secondary lines, subheadline 11 pt for section headers and details), never sizes picked one by one; times use
///   monospaced digits so columns of them line up;
/// - colour: semantic colours only (label / secondaryLabel / tertiaryLabel, separator, controlAccent), so light and
///   dark mode both come for free; orange is kept for "needs you" (a mark with nothing said about it);
/// - space: a 4 pt grid — 4 between a line and its detail, 8 inside a group, 12 between groups, 20 window margins;
/// - shape: the rounder corners of the current system (8 pt thumbnails, 12 pt picture and cards), hairline
///   separators; controls (toolbar, view switch) on Liquid Glass, content (picture, cards) left plain.
enum BoardStyle {
    static let margin: CGFloat = 20
    static let group: CGFloat = 12
    static let inner: CGFloat = 8
    static let tight: CGFloat = 4

    static let thumbRadius: CGFloat = 8
    static let pictureRadius: CGFloat = 12
    static let cardRadius: CGFloat = 12

    /// the page header and the lower pane's control bar share one height, so their contents line up
    static let barHeight: CGFloat = 40
    /// the least room kept around the picture
    static let picturePad: CGFloat = 12

    /// The windows read one point larger than the system's text styles (13 → 14 for body text): they are read at
    /// arm's length while checking and explaining marks.
    static let sizeUp: CGFloat = 1
    /// the least size of anything clicked (Apple's guidance for pointer targets: about 28 pt and up)
    static let hit: CGFloat = 30

    /// A system text style, one point up, optionally at another weight.
    static func font(_ style: NSFont.TextStyle, _ weight: NSFont.Weight? = nil) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return .systemFont(ofSize: base.pointSize + sizeUp, weight: weight ?? .regular)
    }
    /// The same text style with digits of equal width (times, counts).
    static func digits(_ style: NSFont.TextStyle, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize + sizeUp, weight: weight)
    }

    static func label(_ text: String, _ style: NSFont.TextStyle, _ weight: NSFont.Weight? = nil,
                      color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font(style, weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    /// An empty state as macOS draws one: a large tertiary symbol, a short title, one line saying what to do.
    static func emptyState(symbol: String, title: NSTextField, detail: NSTextField) -> NSStackView {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        image.contentTintColor = .tertiaryLabelColor
        title.font = font(.title3, .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        detail.font = font(.callout)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping
        let stack = NSStackView(views: [image, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = tight
        stack.setCustomSpacing(group, after: image)
        return stack
    }
}
