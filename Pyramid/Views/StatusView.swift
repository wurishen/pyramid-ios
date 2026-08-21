import SwiftUI

/// 第一阶段原生 UI 渲染：角色状态面板（HP + 好感度）。
///
/// 由 MessageCard 在遍历 RenderTree 时遇到 `.status` 节点时实例化。
/// 纯展示组件：不持有状态、不修改传入数据。
///
/// 设计原则：
/// - **只读**：`hp` / `affection` 通过初始化参数传入，不查 store、不调网络。
/// - **iOS 17+ 视觉风格**：圆角面板 + 半透明背景 + 大字号数值，符合酒馆风格。
/// - **轻量**：不含动画、不含交互（后续如需点击/滑入可单独迭代）。
struct StatusView: View {
    let hp: Int
    let affection: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("状态")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            statRow(label: "HP", value: hp, color: hpColor(for: hp))
            statRow(label: "好感度", value: affection, color: .accentColor)
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
    private func statRow(label: String, value: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(value)")
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    /// HP 高于 60 显示 accent（绿系），30-60 显示橙色，低于 30 显示红色。
    private func hpColor(for hp: Int) -> Color {
        if hp >= 60 { return .green }
        if hp >= 30 { return .orange }
        return .red
    }
}

// MARK: - SwiftUI Preview

#Preview("Status - full HP") {
    StatusView(hp: 80, affection: 65)
        .padding()
        .background(Color(.systemBackground))
}

#Preview("Status - low HP") {
    StatusView(hp: 20, affection: 90)
        .padding()
        .background(Color(.systemBackground))
}

#Preview("Status - mid HP") {
    StatusView(hp: 45, affection: 30)
        .padding()
        .background(Color(.systemBackground))
}

// MARK: - 通用字段状态面板

/// `<status>` 通用字段面板（HP / 好感度 / 金币 / 饱腹 / 法力 等任意字段）。
///
/// 视觉与 `StatusView` 一致（圆角、systemGray6、标题「状态」），
/// 字号 / padding / 圆角按 `scale` 缩放。`label` 大小写不敏感等于 `"HP"` 且
/// `value` 可解析为整数时，沿用 `StatusView` 的颜色梯度（≥60 绿 / ≥30 橙 / 否则红）；
/// 其余字段用 accent 色。
///
/// 只读；不点击不写入。由 MessageCard 在遇到 `.statusFields` 节点时实例化。
struct StatusFieldsView: View {
    let fields: [StatusField]
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
                Text("状态")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(fields) { field in
                fieldRow(label: field.label, value: field.value)
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .overlay(
            RoundedRectangle(cornerRadius: 10 * scale)
                .stroke(Color(.systemGray4), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10 * scale))
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
        if label.lowercased() == "hp", let v = Int(value) {
            if v >= 60 { return .green }
            if v >= 30 { return .orange }
            return .red
        }
        return .accentColor
    }
}

#if DEBUG
#Preview("StatusFields - mixed fields") {
    StatusFieldsView(fields: [
        StatusField(label: "HP", value: "80"),
        StatusField(label: "好感度", value: "65"),
        StatusField(label: "金币", value: "200"),
        StatusField(label: "饱腹", value: "饱"),
    ], scale: 1.0)
    .padding()
    .background(Color(.systemBackground))
}

#Preview("StatusFields - low HP only") {
    StatusFieldsView(fields: [
        StatusField(label: "HP", value: "20"),
        StatusField(label: "好感度", value: "90"),
    ], scale: 1.0)
    .padding()
    .background(Color(.systemBackground))
}
#endif
