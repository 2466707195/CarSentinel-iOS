import SwiftUI

/// 按权重分配宽度的横排容器，等价 Android 的 `Row { ... Modifier.weight(w) }`。
///
/// 用 `Layout` 实现，保证 1.2 : 1 这类比例是**精确**的，
/// 不依赖 `.frame(maxWidth: .infinity)` 在 HStack 里的分配行为。
struct WeightedHStack: Layout {

    var spacing: CGFloat = 10
    var weights: [CGFloat]

    private var totalWeight: CGFloat {
        max(weights.reduce(0, +), 0.0001)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        let maxWidth = proposal.width ?? fallbackWidth(subviews: subviews)
        let available = max(maxWidth - gaps, 0)

        var height: CGFloat = 0
        for index in subviews.indices {
            let width = widthFor(index: index, count: subviews.count, available: available)
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: width, height: proposal.height)
            )
            height = max(height, size.height)
        }
        return CGSize(width: maxWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        let available = max(bounds.width - gaps, 0)
        var x = bounds.minX

        for index in subviews.indices {
            let width = widthFor(index: index, count: subviews.count, available: available)
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + spacing
        }
    }

    private func widthFor(index: Int, count: Int, available: CGFloat) -> CGFloat {
        guard index < weights.count, available > 0 else { return available }
        return available * (weights[index] / totalWeight)
    }

    /// 父容器没给宽度提案时（例如在 VStack 里），退回子视图的理想宽度，
    /// 否则整行会被压成 0 宽、按钮直接消失。
    private func fallbackWidth(subviews: Subviews) -> CGFloat {
        let ideal = subviews.reduce(CGFloat(0)) { acc, sub in
            max(acc, sub.sizeThatFits(.unspecified).width)
        }
        return ideal + spacing * CGFloat(max(subviews.count - 1, 0))
    }
}
