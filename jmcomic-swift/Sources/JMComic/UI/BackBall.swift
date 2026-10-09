import SwiftUI

/// 往右滑时从侧栏分界线滑出的「返回」小球（样式对齐工具栏那些圆形按钮）。
struct BackBall: View {
    /// 0…1，1 = 到位（即将返回）
    let progress: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
            Circle()
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.75))
        }
        .frame(width: 46, height: 46)
        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        // 越滑越大、越实，到位时最明显
        .scaleEffect(0.70 + 0.30 * progress)
        .opacity(0.30 + 0.70 * progress)
        .padding(.leading, 14)
    }
}
