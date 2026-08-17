import SwiftUI
import UIKit

struct AvatarView: View {
    let imageData: Data?
    let name: String
    var size: CGFloat = 36

    /// Item 7 H2：异步解码/降采样后的 UIImage。命中缓存 → 同帧可见；
    /// 未命中 → 占位 + 后台 ImageIO thumbnail，落地后写回 @State。
    @State private var loaded: UIImage?

    var body: some View {
        // 命中缓存时同步查询（O(1) NSCache 查表），body 内一帧可见。
        let cached: UIImage? = imageData.flatMap {
            AvatarImageCache.shared.image(for: $0, pointSize: size)
        }
        Group {
            if let image = loaded ?? cached {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: imageData) {
            await loadAvatar()
        }
    }

    @MainActor
    private func loadAvatar() async {
        guard let data = imageData else {
            loaded = nil
            return
        }
        // 命中缓存 / 命中刚 load 的直接路径：把 UIImage 设上即可。
        if let image = AvatarImageCache.shared.image(for: data, pointSize: size) {
            loaded = image
            return
        }
        // 未命中：调度后台 decode + 降采样；返回后再写 @State。
        let image = await AvatarImageCache.shared.load(data: data, pointSize: size)
        loaded = image
    }

    private var placeholder: some View {
        ZStack {
            Color.accentColor.opacity(0.15)
            Text(initial)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var initial: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased()
    }
}
