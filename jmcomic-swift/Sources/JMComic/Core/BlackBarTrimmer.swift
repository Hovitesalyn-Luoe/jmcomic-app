import CoreGraphics
import Foundation

/// 贴边黑带裁剪（只影响显示，不动磁盘原图）。
///
/// 铁律：只裁"贴边的、整行/整列贯穿的纯黑带"——内容里的黑一个像素都不碰。
/// - 某行/列必须 ≥99.9% 像素是纯黑（亮度 < 16）才算黑带；
///   里面只要有一个亮点（字、网点、火花）就立刻停手不裁。
/// - 每边最多裁掉该边的 15%；一路黑过去的多半是整页黑幕/黑转场，原样保留。
/// - 被裁掉的像素本来就是纯黑，裁前裁后视觉零损失。
enum BlackBarTrimmer {

    struct Trim: Equatable {
        /// 原图坐标系里的保留区域
        let rect: CGRect
        /// 裁后 高/宽
        let ratio: CGFloat
    }

    /// 每边最大裁剪比例（超过这么多的黑多半是内容/黑幕，不裁）
    private static let maxFraction: CGFloat = 0.15
    /// 一行/列里纯黑像素占比达到这个才算黑带（99.9%：JPEG 噪点放行，白点不放行）
    private static let blackCoverage = 0.999
    /// 亮度（RGB 最大通道）低于此视为纯黑
    private static let blackLevel = 16

    static func analyze(_ image: CGImage) -> Trim {
        let w = image.width, h = image.height
        guard w > 4, h > 4 else { return full(image) }

        // 解码到位图（一次性，随后逐行/列扫）
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return full(image) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        @inline(__always) func isBlack(_ i: Int) -> Bool {
            max(buf[i], buf[i + 1], buf[i + 2]) < blackLevel
        }

        /// 这一行 [y] 是否整行黑
        func blackRow(_ y: Int) -> Bool {
            var n = 0
            let base = y * w * 4
            for x in 0..<w where isBlack(base + x * 4) { n += 1 }
            return Double(n) >= Double(w) * blackCoverage
        }
        /// 这一列 [x] 是否整列黑
        func blackCol(_ x: Int) -> Bool {
            var n = 0
            for y in 0..<h where isBlack((y * w + x) * 4) { n += 1 }
            return Double(n) >= Double(h) * blackCoverage
        }

        let maxTB = Int(CGFloat(h) * maxFraction)
        let maxLR = Int(CGFloat(w) * maxFraction)

        var top = 0
        while top < maxTB, blackRow(top) { top += 1 }
        var bottom = 0
        while bottom < maxTB, blackRow(h - 1 - bottom) { bottom += 1 }
        var left = 0
        while left < maxLR, blackCol(left) { left += 1 }
        var right = 0
        while right < maxLR, blackCol(w - 1 - right) { right += 1 }

        // 整页黑 / 黑幕转场：裁到上限还一路黑 → 当内容，原样保留
        if top + bottom >= maxTB * 2 || left + right >= maxLR * 2 {
            return full(image)
        }
        // 一点黑带都没有
        if top == 0, bottom == 0, left == 0, right == 0 {
            return full(image)
        }

        let rect = CGRect(x: left, y: top,
                          width: w - left - right, height: h - top - bottom)
        guard rect.width > 1, rect.height > 1 else { return full(image) }
        return Trim(rect: rect,
                    ratio: rect.height / rect.width)
    }

    private static func full(_ image: CGImage) -> Trim {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        return Trim(rect: CGRect(x: 0, y: 0, width: w, height: h), ratio: h / w)
    }
}

/// 分析结果缓存（同一张图只分析一次）。键必须唯一到"某一张图"（用图片 URL/路径）。
/// 用锁保护：分析可能发生在图片加载的后台线程。
final class TrimCache {
    static let shared = TrimCache()
    private var map: [String: BlackBarTrimmer.Trim] = [:]
    private let lock = NSLock()

    /// 已分析过就直接返回，否则现算并记下
    func trim(for key: String, image: CGImage) -> BlackBarTrimmer.Trim {
        lock.lock(); defer { lock.unlock() }
        if let t = map[key] { return t }
        let t = BlackBarTrimmer.analyze(image)
        map[key] = t
        return t
    }

    /// 只查不算
    func cached(_ key: String) -> BlackBarTrimmer.Trim? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }
}
