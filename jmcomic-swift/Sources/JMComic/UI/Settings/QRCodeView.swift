import SwiftUI
import AppKit

/// 二维码渲染：CoreImage CIFilter.qrCodeGenerator → CGImage → NSImage。
/// 内容即 LanSyncServer.qrConfigString() 的自包含配置串。
struct QRCodeView: View {
    let text: String

    var body: some View {
        Group {
            if let ns = Self.image(for: text) {
                Image(nsImage: ns)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if !text.isEmpty {
                Text("二维码生成失败").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func image(for text: String) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage, ci.extent.width > 0 else { return nil }
        // 原始模块矩阵很小，放大到 ~300px 供屏显清晰
        let scale = 300.0 / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
