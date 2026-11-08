import SwiftUI

/// "Scanned" / "Manual entry" badge shown everywhere a fill appears.
struct SourceBadge: View {
    let source: DataSource
    var edited: Bool = false
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source.systemImage)
            if !compact {
                Text(source.label)
            }
            if edited {
                Image(systemName: "pencil.circle.fill")
                    .accessibilityHidden(true)
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(source == .scan ? Color.teal : Color.purple)
        .background((source == .scan ? Color.teal : Color.purple).opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.label + (edited ? ", edited after scan" : ""))
    }
}

/// Green / yellow / red OCR confidence levels.
enum ConfidenceLevel {
    case high, medium, low

    init(_ confidence: Double) {
        switch confidence {
        case 0.8...: self = .high
        case 0.5..<0.8: self = .medium
        default: self = .low
        }
    }

    var color: Color {
        switch self {
        case .high: .green
        case .medium: .yellow
        case .low: .red
        }
    }

    var description: String {
        switch self {
        case .high: "high"
        case .medium: "medium"
        case .low: "low"
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        let level = ConfidenceLevel(confidence)
        Label("\(Int((confidence * 100).rounded()))% OCR", systemImage: "circle.fill")
            .font(.caption2.weight(.semibold))
            .labelStyle(DotLabelStyle(color: level.color))
            .accessibilityLabel("OCR confidence \(Int((confidence * 100).rounded())) percent, \(level.description)")
    }
}

private struct DotLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            configuration.title
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        SourceBadge(source: .scan)
        SourceBadge(source: .scan, edited: true)
        SourceBadge(source: .manual)
        SourceBadge(source: .manual, compact: true)
        ConfidenceBadge(confidence: 0.93)
        ConfidenceBadge(confidence: 0.6)
        ConfidenceBadge(confidence: 0.3)
    }
}
