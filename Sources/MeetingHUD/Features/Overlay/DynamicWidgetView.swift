import SwiftUI

/// Renders a single DynamicWidget based on its type.
struct DynamicWidgetView: View {
    let widget: DynamicWidget

    var body: some View {
        Group {
            switch widget.type {
            case .stat:
                if let payload = widget.stat {
                    StatWidgetContent(payload: payload, widget: widget)
                }
            case .list:
                if let payload = widget.list {
                    ListWidgetContent(payload: payload, widget: widget)
                }
            case .quote:
                if let payload = widget.quote {
                    QuoteWidgetContent(payload: payload, widget: widget)
                }
            case .alert:
                if let payload = widget.alert {
                    AlertWidgetContent(payload: payload, widget: widget)
                }
            case .progress:
                if let payload = widget.progress {
                    ProgressWidgetContent(payload: payload, widget: widget)
                }
            case .markdown:
                if let payload = widget.markdown {
                    MarkdownWidgetContent(payload: payload, widget: widget)
                }
            case .kv:
                if let payload = widget.kv {
                    KVWidgetContent(payload: payload, widget: widget)
                }
            case .timeline:
                if let payload = widget.timeline {
                    TimelineWidgetContent(payload: payload, widget: widget)
                }
            case .barChart:
                if let payload = widget.barChart {
                    BarChartWidgetContent(payload: payload, widget: widget)
                }
            }
        }
    }
}

// MARK: - Widget Header

private struct WidgetHeader: View {
    let widget: DynamicWidget

    var body: some View {
        if let title = widget.title {
            HStack(spacing: 4) {
                if let icon = widget.icon {
                    Image(systemName: icon)
                        .font(.system(size: 8))
                        .foregroundStyle(widget.resolvedColor)
                }
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Stat Widget

private struct StatWidgetContent: View {
    let payload: DynamicWidget.StatPayload
    let widget: DynamicWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetHeader(widget: widget)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(payload.value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(widget.resolvedColor)
                if let trend = payload.trend, !trend.isEmpty {
                    Text(trend)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            Text(payload.label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .widgetCard(color: widget.resolvedColor)
    }
}

// MARK: - List Widget

private struct ListWidgetContent: View {
    let payload: DynamicWidget.ListPayload
    let widget: DynamicWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(widget: widget)
            ForEach(Array(payload.items.prefix(6).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 4) {
                    Circle()
                        .fill(widget.resolvedColor)
                        .frame(width: 4, height: 4)
                        .padding(.top, 4)
                    Text(item)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
            }
        }
        .widgetCard(color: widget.resolvedColor)
    }
}

// MARK: - Quote Widget

private struct QuoteWidgetContent: View {
    let payload: DynamicWidget.QuotePayload
    let widget: DynamicWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(widget: widget)
            Text("\"\(payload.text)\"")
                .font(.system(size: 10))
                .italic()
                .lineLimit(3)
            HStack(spacing: 4) {
                if let speaker = payload.speaker {
                    Text("- \(speaker)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if let annotation = payload.annotation {
                    Text(annotation)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(widget.resolvedColor.opacity(0.12), in: Capsule())
                }
            }
        }
        .widgetCard(color: widget.resolvedColor)
    }
}

// MARK: - Alert Widget

private struct AlertWidgetContent: View {
    let payload: DynamicWidget.AlertPayload
    let widget: DynamicWidget

    private var alertColor: Color {
        switch payload.severity?.lowercased() {
        case "error", "critical": return .red
        case "warning": return .orange
        case "info": return .blue
        default: return widget.resolvedColor
        }
    }

    private var alertIcon: String {
        switch payload.severity?.lowercased() {
        case "error", "critical": return "exclamationmark.triangle.fill"
        case "warning": return "exclamationmark.circle.fill"
        case "info": return "info.circle.fill"
        default: return widget.icon ?? "bell.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: alertIcon)
                .font(.system(size: 11))
                .foregroundStyle(alertColor)
            Text(payload.message)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(3)
        }
        .widgetCard(color: alertColor)
    }
}

// MARK: - Progress Widget

private struct ProgressWidgetContent: View {
    let payload: DynamicWidget.ProgressPayload
    let widget: DynamicWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(widget: widget)
            ForEach(Array(payload.items.prefix(8).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 9))
                        .foregroundStyle(item.done ? .green : .secondary)
                    Text(item.label)
                        .font(.system(size: 10))
                        .strikethrough(item.done)
                        .foregroundStyle(item.done ? .secondary : .primary)
                        .lineLimit(1)
                }
            }
            let done = payload.items.filter(\.done).count
            let total = payload.items.count
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .progressViewStyle(.linear)
                    .tint(widget.resolvedColor)
            }
        }
        .widgetCard(color: widget.resolvedColor)
    }
}

// MARK: - Markdown Widget

private struct MarkdownWidgetContent: View {
    let payload: DynamicWidget.MarkdownPayload
    let widget: DynamicWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(widget: widget)
            if let attributed = try? AttributedString(markdown: payload.content) {
                Text(attributed)
                    .font(.system(size: 10))
                    .lineLimit(8)
            } else {
                Text(payload.content)
                    .font(.system(size: 10))
                    .lineLimit(8)
            }
        }
        .widgetCard(color: widget.resolvedColor)
    }
}

// MARK: - KV Widget

private struct KVWidgetContent: View {
    let payload: DynamicWidget.KVPayload
    let widget: DynamicWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(widget: widget)
            ForEach(Array(payload.pairs.prefix(6).enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.key)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(pair.value)
                        .font(.system(size: 10, weight: .medium))
                }
            }
        }
        .widgetCard(color: widget.resolvedColor)
    }
}

// MARK: - Timeline Widget

private struct TimelineWidgetContent: View {
    let payload: DynamicWidget.TimelinePayload
    let widget: DynamicWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(widget: widget)
            ForEach(Array(payload.events.prefix(6).enumerated()), id: \.offset) { _, event in
                HStack(alignment: .top, spacing: 6) {
                    Text(event.time)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(widget.resolvedColor)
                        .frame(width: 36, alignment: .trailing)
                    Circle()
                        .fill(widget.resolvedColor)
                        .frame(width: 5, height: 5)
                        .padding(.top, 3)
                    Text(event.desc)
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
            }
        }
        .widgetCard(color: widget.resolvedColor)
    }
}

// MARK: - Bar Chart Widget

private struct BarChartWidgetContent: View {
    let payload: DynamicWidget.BarChartPayload
    let widget: DynamicWidget

    private var maxValue: Double {
        payload.bars.map(\.value).max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            WidgetHeader(widget: widget)
            ForEach(Array(payload.bars.prefix(6).enumerated()), id: \.offset) { _, bar in
                HStack(spacing: 6) {
                    Text(bar.label)
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .frame(maxWidth: 60, alignment: .leading)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(widget.resolvedColor.opacity(0.2))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(widget.resolvedColor)
                                    .frame(width: maxValue > 0 ? geo.size.width * CGFloat(bar.value / maxValue) : 0)
                            }
                    }
                    .frame(height: 6)

                    Text(formatValue(bar.value))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .widgetCard(color: widget.resolvedColor)
    }

    private func formatValue(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
    }
}

// MARK: - Card Modifier

private struct WidgetCardModifier: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(color.opacity(0.15), lineWidth: 0.5)
            )
    }
}

private extension View {
    func widgetCard(color: Color) -> some View {
        modifier(WidgetCardModifier(color: color))
    }
}
