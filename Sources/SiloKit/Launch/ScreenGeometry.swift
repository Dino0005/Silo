import AppKit

/// The real screen's native pixel resolution, formatted for `explorer /desktop=Name,<geometry>` — the
/// string `LaunchOrchestrator.makePlan`'s `desktopGeometry` parameter expects. Deliberately isolated in
/// its own AppKit file so `LaunchOrchestrator` itself stays free of AppKit: `makePlan` is a pure,
/// exhaustively-tested function, and keeping AppKit out of it means those tests never need a real screen
/// or a MainActor hop — callers resolve the geometry here, at the UI layer, and pass the string down.
public enum ScreenGeometry {
    /// `"<width>x<height>"` in real pixels, or nil if there's no screen to ask (off-main misuse, or a
    /// genuinely headless session). `NSScreen.frame` is reported in **points**; a Retina panel's actual
    /// pixel count is that times `backingScaleFactor` (e.g. a 1512×982-point MacBook Pro panel at 2x is
    /// 3024×1964 real pixels) — the figure `explorer /desktop=` needs, since Wine renders at the panel's
    /// native pixel resolution, not its point size.
    @MainActor
    public static func nativeResolution(screen: NSScreen? = .main) -> String? {
        guard let screen else { return nil }
        let scale = screen.backingScaleFactor
        let width = Int((screen.frame.width * scale).rounded())
        let height = Int((screen.frame.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        return "\(width)x\(height)"
    }
}
