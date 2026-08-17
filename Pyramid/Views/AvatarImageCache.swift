import UIKit
import ImageIO

/// Item 7 H2：头像解码 + 降采样缓存。
///
/// 旧实现每次 AvatarView body 重新评估都会在主线程上 `UIImage(data: data)`：
/// 100 条消息 × 滚动 → 反复 100+ 次 PNG 解码，主线程明显卡顿。
/// 现在按 (data 内容 + 像素尺寸) 缓存降采样后的 UIImage，
/// 首次访问在后台并发队列用 ImageIO 制作 thumbnail (maxPixelSize = ptSize × scale × 2)
/// 后写回 NSCache。命中缓存后走 O(1) 同步查询，不再触发 ImageIO。
///
/// `NSCache` 在内存压力下自动淘汰；`countLimit` + `totalCostLimit` 兜底。
final class AvatarImageCache {
    static let shared = AvatarImageCache()

    private let cache = NSCache<NSData, UIImage>()
    private let queue = DispatchQueue(
        label: "pyramid.avatar.decode",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 16 * 1024 * 1024 // 16 MB
    }

    /// O(1) 同步查询。命中返回 UIImage，未命中返回 nil（不阻塞）。
    func image(for data: Data, pointSize: CGFloat) -> UIImage? {
        cache.object(forKey: key(for: data, pointSize: pointSize))
    }

    /// 异步取图。命中 → 同步返回；未命中 → 后台 ImageIO decode + downsample + 写缓存。
    func load(data: Data, pointSize: CGFloat) async -> UIImage? {
        let cacheKey = key(for: data, pointSize: pointSize)
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(returning: nil)
                    return
                }
                let image = Self.decodeAndDownsample(data: data, pointSize: pointSize)
                if let image {
                    self.cache.setObject(image, forKey: cacheKey, cost: Self.estimatedCost(of: image))
                }
                cont.resume(returning: image)
            }
        }
    }

    /// 显式淘汰某个 data 的全部尺寸缓存（角色卡头像被替换时调用，使旧图不再命中）。
    func invalidate(data: Data) {
        // NSCache 没有按部分 key 删除；遍历代价高。角色卡头像替换极少见，
        // 主动 invalidate 先不上，留作后续按需扩展。
        _ = data
    }

    // MARK: - 私有辅助

    /// 把 pointSize 的 8 字节二进制前缀拼到 data 前部，作为 NSCache key。
    /// NSData isEqual 走内容比较，不同尺寸自然落到不同 key。
    private func key(for data: Data, pointSize: CGFloat) -> NSData {
        var combined = Data()
        var size = pointSize
        withUnsafeBytes(of: &size) { rawBuf in
            combined.append(contentsOf: rawBuf)
        }
        combined.append(data)
        return combined as NSData
    }

    /// ImageIO 制作 thumbnail：根据目标像素上限把大图压到合理大小。
    /// 比 `UIImage(data:)` → `image.draw(in:)` 缩放更省内存。
    private static func decodeAndDownsample(data: Data, pointSize: CGFloat) -> UIImage? {
        let scale = UIScreen.main.scale
        let maxPixel = max(1, pointSize) * scale * 2 // 2x 给 retina 留余量
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let src = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(
            src,
            0,
            thumbOptions as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    private static func estimatedCost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else {
            return Int(image.size.width * image.size.height * 4)
        }
        return cg.bytesPerRow * cg.height
    }
}
