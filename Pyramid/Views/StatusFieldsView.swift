import SwiftUI

/// 通用 `<status>` 面板：模型输出里任意 key/value 字段（HP / 好感度 / 金币 / 饱腹 / 法力 等）。
///
/// 渲染规则：
/// - 每个 `StatusField` 一行：`label` 用 secondary 色小字，`value` 用大号粗体。
/// - 字段名为 `HP` 且 value 是整数 → 沿用 SPEC §2.1.2 颜色梯度（≥60 绿 / 30-60 橙 / <30 红）。
/// - 其余字段 → accent 色。
/// - 与 `StatusView` 视觉一致（圆角 gray6 背景 + gray4 描边 + cornerRadius 10）。
struct StatusFieldsView: View {
    let fields: [StatusField]
    var scale: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("状态")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(fields) { field in
                fieldRow(label: field.label, value: field.value)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func fieldRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(color(forLabel: label, value: value))
        }
    }

    private func color(forLabel label: String, value: String) -> Color {
        if label == "HP", let v = Int(value) {
            if v >= 60 { return .green }
            if v >= 30 { return .orange }
            return .red
        }
        return .accentColor
    }
}

#if DEBUG
// MARK: - SwiftUI Preview

#Preview("StatusFields - mixed fields") {
    StatusFieldsView(fields: [
        StatusField(label: "HP", value: "80"),
        StatusField(label: "好感度", value: "65"),
        StatusField(label: "金币", value: "200"),
        StatusField(label: "饱腹", value: "饱"),
    ])
    .padding()
    .background(Color(.systemBackground))
}

#Preview("StatusFields - low HP only") {
    StatusFieldsView(fields: [
        StatusField(label: "HP", value: "20"),
        StatusField(label: "好感度", value: "90"),
    ])
    .padding()
    .background(Color(.systemBackground))
}
#endif
