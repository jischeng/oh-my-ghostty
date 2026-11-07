import SwiftUI

/// The terminal remains the interaction surface; status never authorizes input.
struct AgentActivityView: View {
    let activity: MobileAgentActivity

    private var status: SessionStatus {
        switch activity.state {
        case .idle: .idle
        case .working: .working
        case .done: .done
        case .needsAttention, .error: .needsAttention
        }
    }

    private var label: String {
        switch activity.state {
        case .idle: "就绪"
        case .working: "正在处理"
        case .done: "已完成"
        case .needsAttention:
            activity.attention == "permission" ? "等待授权"
                : activity.attention == "question" ? "等待回答" : "需要你处理"
        case .error: "出错"
        }
    }

    private var icon: String? {
        switch activity.agentID {
        case "codex": "AgentOpenAI"
        case "claude": "AgentClaude"
        case "pi": "AgentPi"
        case "antigravity": "AgentAntigravity"
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if activity.state == .working {
                WorkingIndicator(tint: .primary)
                    .frame(width: 22, height: 22)
            } else if let icon {
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "terminal")
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(activity.displayName) · \(label)")
                    .font(.subheadline.weight(.semibold))
                if let message = activity.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let progress = activity.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if activity.state == .error {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                StatusDot(status: status)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.activity")
    }
}
