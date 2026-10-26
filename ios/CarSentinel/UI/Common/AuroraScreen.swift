import SwiftUI

/// 页面骨架：顶栏 + 滚动内容 + 底部悬浮操作条。
///
/// - `topBar`：自绘顶栏（`AppTopBar`）
/// - `content`：滚动内容
/// - `bar`：底部操作条（`GlassBar`），浮在内容之上
struct AuroraScreen<Top: View, Content: View, Bar: View>: View {

    @ViewBuilder var topBar: () -> Top
    @ViewBuilder var content: () -> Content
    @ViewBuilder var bar: () -> Bar

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topBar()
                content()
            }
            bar()
                .padding(.horizontal, AuroraMetrics.pagePadding)
                .padding(.bottom, 10)
        }
    }
}

/// 通用滚动内容容器：统一左右边距、卡片间距、底部留白。
struct AuroraScrollView<Content: View>: View {

    var bottomInset: CGFloat = AuroraMetrics.listBottomInset
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AuroraMetrics.cardSpacing) {
                content()
            }
            .padding(.horizontal, AuroraMetrics.pagePadding)
            .padding(.top, 4)
            .padding(.bottom, bottomInset)
        }
        .scrollIndicators(.hidden)
    }
}
