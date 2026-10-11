import SwiftUI
import CoreGraphics


// MARK: - 页显示单元

/// 核心里的一页：加载 →（可选裁黑）→ 显示。支持双击局部放大。
/// 图怎么来由 [loadImage] 决定（在线=ImageStore 下载缓存；本地=ImageIO 读文件）。
struct ReaderPageCell: View {
    let index: Int
    /// 显示宽度（高度按 ratio 推）
    let width: CGFloat
    /// 高/宽（裁黑开着时是裁后的比例）
    let ratio: CGFloat
    /// 裁掉贴边黑带（只影响显示）
    let trimBlack: Bool
    /// 裁剪缓存键：唯一到"某一张图"（图片 URL/路径），不同本子同页号不许撞
    let pageKey: String
    let loadImage: (Int) async -> CGImage?
    /// 分析完裁剪框、布局该按新比例重排时调用
    let onTrim: () -> Void

    @State private var image: CGImage?
    @State private var failed = false
    @State private var zoomed = false
    @State private var zoomAnchor = UnitPoint(x: 0.5, y: 0.5)

    private var targetSize: CGSize {
        CGSize(width: width, height: (width * ratio).rounded())
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: targetSize.width, height: targetSize.height)
                    .scaleEffect(zoomed ? 2 : 1, anchor: zoomAnchor)
                    .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                        let h = max(targetSize.height, 1)
                        zoomAnchor = UnitPoint(x: loc.x / max(width, 1), y: loc.y / h)
                        zoomed.toggle()
                    }
            } else {
                Rectangle()
                    .fill(Color(white: 0.13))
                    .frame(width: targetSize.width, height: targetSize.height)
                    .overlay {
                        if failed {
                            VStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                Text("加载失败").font(.caption)
                                Button("重试") { failed = false; load() }
                                    .buttonStyle(.link)
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .clipped()
        .task(id: index) { load() }
    }

    private func load() {
        Task {
            guard let img = await loadImage(index) else {
                await MainActor.run { self.failed = true }
                return
            }
            if trimBlack {
                // 黑带分析放后台：逐行扫全图不便宜
                let trim = await Task.detached(priority: .utility) {
                    TrimCache.shared.trim(for: pageKey, image: img)
                }.value
                let shown = img.cropping(to: trim.rect) ?? img
                await MainActor.run {
                    self.image = shown
                    onTrim()
                }
            } else {
                await MainActor.run { self.image = img }
            }
        }
    }
}
