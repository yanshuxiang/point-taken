import AppKit
import ImageIO

/// An image file's first frame.
func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// A display's pixels per point (2 on Retina).
func backingScale(forDisplay id: CGDirectDisplayID) -> CGFloat {
    NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    })?.backingScaleFactor ?? 2
}
