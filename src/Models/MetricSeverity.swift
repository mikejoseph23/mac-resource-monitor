import SwiftUI

/// Single source of truth for metric health state across every surface —
/// menu bar, dashboard cards, process rows, disk. Owns the color, the
/// colorblind-safe glyph, and the canonical thresholds so a "warning" looks
/// and reads identically everywhere.
///
/// Before this existed each surface rolled its own thresholds and palette
/// (menu bar green/yellow/red at 50/80, cards green/orange/red at 70/90,
/// process rows 40/80, disk 80/95). Route everything through here instead.
enum MetricSeverity {
    case normal
    case warning
    case critical

    /// Semantic fill color. Green / orange / red — the same three tones on
    /// every surface. (The menu bar previously used yellow for its middle
    /// state; unified to orange here.)
    var color: Color {
        switch self {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }

    /// Shape-distinct SF Symbol so severity reads without relying on color
    /// alone (colorblind-safe): a calm dot when healthy, a triangle for a
    /// warning, an octagon for critical. The three glyphs differ in outline
    /// shape, not just hue.
    var glyph: String {
        switch self {
        case .normal:   return "circle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    /// Point size the glyph renders at. Normal stays a small quiet dot (it
    /// matches the original 6px indicator); the alert symbols are a touch
    /// larger so they draw the eye.
    var glyphSize: CGFloat {
        self == .normal ? 6 : 11
    }

    /// Human-readable label for tooltips / VoiceOver.
    var label: String {
        switch self {
        case .normal:   return "Normal"
        case .warning:  return "Warning"
        case .critical: return "Critical"
        }
    }

    // MARK: - Canonical thresholds

    /// Standard utilization scale (CPU, GPU, memory, per-process load, and
    /// the menu-bar rows). Warning at 70%, critical at 90%.
    static func utilization(_ percent: Double) -> MetricSeverity {
        from(percent: percent, warningAt: 70, criticalAt: 90)
    }

    /// Capacity-fill scale (disk space). A drive is fine until it's nearly
    /// full, so the bar sits higher: warning at 80%, critical at 95%.
    static func capacity(_ percent: Double) -> MetricSeverity {
        from(percent: percent, warningAt: 80, criticalAt: 95)
    }

    /// General factory from a 0–100 percentage. Prefer the named presets
    /// above; this stays available for one-off scales (e.g. power headroom).
    static func from(percent: Double, warningAt: Double = 70, criticalAt: Double = 90) -> MetricSeverity {
        if percent >= criticalAt { return .critical }
        if percent >= warningAt  { return .warning }
        return .normal
    }
}
