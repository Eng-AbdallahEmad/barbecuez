import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Main Widget

struct OrderTrackingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrderTrackingAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // ── Expanded ──────────────────────────────────────────────
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: statusIcon(context.state.status))
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Barbecuez")
                                .font(.caption2.bold())
                                .foregroundStyle(.orange)
                            Text("#\(context.attributes.orderNumber)")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(context.state.etaMinutes)")
                            .font(.title.bold())
                            .foregroundStyle(.orange)
                            .monospacedDigit()
                        Text("min ETA")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        // Status label
                        Text(context.state.statusLabel)
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Progress track
                        DeliveryProgressView(
                            status: context.state.status,
                            progress: context.state.progress
                        )

                        // Driver row (if assigned)
                        if let driver = context.state.driverName {
                            HStack(spacing: 6) {
                                Image(systemName: "bicycle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text(driver)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Text(context.attributes.totalAmount)
                                    .font(.caption.bold())
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: statusIcon(context.state.status))
                    .foregroundStyle(.orange)
                    .font(.callout)
            } compactTrailing: {
                Text("\(context.state.etaMinutes)m")
                    .foregroundStyle(.orange)
                    .font(.caption.bold())
                    .monospacedDigit()
            } minimal: {
                Image(systemName: statusIcon(context.state.status))
                    .foregroundStyle(.orange)
            }
            .widgetURL(URL(string: "barbecuez://order/\(context.attributes.orderNumber)"))
            .keylineTint(.orange)
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "pending":          return "clock.fill"
        case "preparing":        return "flame.fill"
        case "ready":            return "bag.fill"
        case "out_for_delivery": return "bicycle"
        case "delivered":        return "checkmark.circle.fill"
        default:                 return "circle.fill"
        }
    }
}

// MARK: - Lock Screen View

struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<OrderTrackingAttributes>

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.2))
                            .frame(width: 36, height: 36)
                        Image(systemName: statusIcon(context.state.status))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Barbecuez")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text("Order #\(context.attributes.orderNumber)")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(context.state.etaMinutes)")
                            .font(.title2.bold())
                            .foregroundStyle(.orange)
                            .monospacedDigit()
                        Text("min")
                            .font(.caption)
                            .foregroundStyle(.orange.opacity(0.8))
                    }
                    Text("estimated")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }

            // Divider
            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 1)

            // Status + Progress
            VStack(spacing: 8) {
                HStack {
                    Text(context.state.statusLabel)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text(context.attributes.totalAmount)
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.6))
                }

                DeliveryProgressView(
                    status: context.state.status,
                    progress: context.state.progress
                )
            }

            // Driver info
            if let driver = context.state.driverName {
                HStack(spacing: 8) {
                    Image(systemName: "bicycle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Driver: \(driver)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.black.opacity(0.85))
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "pending":          return "clock.fill"
        case "preparing":        return "flame.fill"
        case "ready":            return "bag.fill"
        case "out_for_delivery": return "bicycle"
        case "delivered":        return "checkmark.circle.fill"
        default:                 return "circle.fill"
        }
    }
}

// MARK: - Delivery Progress Steps

struct DeliveryProgressView: View {
    let status: String
    let progress: Double

    private let steps: [(id: String, icon: String, label: String)] = [
        ("pending",          "clock.fill",            "Received"),
        ("preparing",        "flame.fill",            "Preparing"),
        ("ready",            "bag.fill",              "Ready"),
        ("out_for_delivery", "bicycle",               "On way"),
        ("delivered",        "checkmark.circle.fill", "Delivered"),
    ]

    private var currentStep: Int {
        switch status {
        case "pending":          return 0
        case "preparing":        return 1
        case "ready":            return 2
        case "out_for_delivery": return 3
        case "delivered":        return 4
        default:                 return 0
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                // Step node
                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .fill(index <= currentStep ? Color.orange : Color.white.opacity(0.15))
                            .frame(width: 22, height: 22)
                        Image(systemName: step.icon)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(index <= currentStep ? .black : .white.opacity(0.4))
                    }
                    Text(step.label)
                        .font(.system(size: 7, weight: index == currentStep ? .bold : .regular))
                        .foregroundStyle(index <= currentStep ? .white : .white.opacity(0.35))
                        .lineLimit(1)
                }

                // Connector line (between steps)
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(index < currentStep ? Color.orange : Color.white.opacity(0.15))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .offset(y: -8) // align with step circles
                }
            }
        }
    }
}
