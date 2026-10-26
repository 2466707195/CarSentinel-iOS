import SwiftUI

// === Aurora UI 通用组件（iOS / SwiftUI）===
// 对应 Android 版 `ui/common/Common.kt`。

// MARK: - 极光背景

/// 极光背景：近白底 + 三团很淡的径向色晕，给实白卡片提供层次，但不抢内容。
///
/// 规则：**背景可以淡，内容必须实**。色晕只存在于卡片之间的缝隙里。
struct AuroraBackdrop: View {
    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Aurora.canvas)
            )
            drawGlow(
                in: &context,
                size: size,
                color: Aurora.brand.opacity(0.11),
                center: CGPoint(x: size.width * 0.16, y: size.height * 0.02),
                radius: size.width * 0.85
            )
            drawGlow(
                in: &context,
                size: size,
                color: Aurora.teal.opacity(0.08),
                center: CGPoint(x: size.width * 1.04, y: size.height * 0.68),
                radius: size.width * 0.80
            )
            drawGlow(
                in: &context,
                size: size,
                color: Aurora.rose.opacity(0.05),
                center: CGPoint(x: size.width * 0.02, y: size.height * 0.98),
                radius: size.width * 0.70
            )
        }
        .ignoresSafeArea()
    }

    private func drawGlow(
        in context: inout GraphicsContext,
        size: CGSize,
        color: Color,
        center: CGPoint,
        radius: CGFloat
    ) {
        let shading = GraphicsContext.Shading.radialGradient(
            Gradient(colors: [color, .clear]),
            center: center,
            startRadius: 0,
            endRadius: max(radius, 1)
        )
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: shading
        )
    }
}

// MARK: - 顶栏

/// 自绘顶栏，替代系统 NavigationBar。
struct AppTopBar<Actions: View>: View {

    let title: String
    var subtitle: String? = nil
    var onBack: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Aurora.ink)
                        .frame(width: AuroraMetrics.iconButtonSize, height: AuroraMetrics.iconButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                Spacer().frame(width: 2)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(onBack == nil ? AuroraFont.headlineSmall : AuroraFont.titleLarge)
                    .foregroundStyle(Aurora.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(AuroraFont.bodySmall)
                        .foregroundStyle(Aurora.inkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions()
        }
        .padding(.leading, onBack == nil ? 20 : 4)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

extension AppTopBar where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, onBack: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, onBack: onBack) { EmptyView() }
    }
}

// MARK: - 底部操作条

/// 底部悬浮操作条：实白底 + 细描边 + 柔化投影。
///
/// 虽然叫 "Glass"，但实现是**实白**：不要改成半透明，
/// 半透明底会把阴影透上来，看起来像多垫了一层灰方块。
struct GlassBar<Content: View>: View {

    var contentPadding: EdgeInsets = EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(contentPadding)
            .background(
                AuroraShape.bar
                    .fill(Color.white)
                    .shadow(color: Aurora.barShadow, radius: 10, x: 0, y: 4)
            )
            .overlay(
                AuroraShape.bar.stroke(Aurora.line.opacity(0.55), lineWidth: 1)
            )
            // 浮层必须整块吞点击：空白处点击不能穿透到底下的列表项
            .contentShape(AuroraShape.bar)
            .onTapGesture { }
    }
}

// MARK: - 内容卡片

/// 内容卡片的唯一入口。实白、20pt 圆角、1pt 描边、1pt 阴影、16pt 内边距。
struct SectionCard<Content: View>: View {

    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(AuroraMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AuroraShape.card
                    .fill(Color.white)
                    .shadow(color: Aurora.cardShadow, radius: 4, x: 0, y: 1)
            )
            .overlay(
                AuroraShape.card.stroke(Aurora.line.opacity(0.55), lineWidth: 1)
            )
    }
}

// MARK: - 状态胶囊

/// 状态胶囊：小圆点 + 文字，可点击查看详情。
struct StatusPill: View {

    let text: String
    let color: Color
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(AuroraFont.labelSmall)
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.tint(0.13)))
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
    }
}

// MARK: - 首字方块

/// 首字圆角方块，代替图标，避免"纯文字工程感"。
struct Monogram: View {

    let name: String
    let tone: Color
    var size: CGFloat = 44

    private var letter: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tone.tint(0.13))
            .frame(width: size, height: size)
            .overlay(
                Text(letter)
                    .font(AuroraFont.titleMedium)
                    .fontWeight(.bold)
                    .foregroundStyle(tone)
            )
    }
}

// MARK: - 空状态插画

/// 空状态插画：云 + 下箭头。
struct DownloadIllustration: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let primary = Aurora.brand

            context.fill(
                Path(ellipseIn: CGRect(
                    x: w * 0.5 - w * 0.42, y: h * 0.52 - w * 0.42,
                    width: w * 0.84, height: w * 0.84
                )),
                with: .color(primary.opacity(0.07))
            )

            // 云
            context.fill(
                Path(ellipseIn: CGRect(
                    x: w * 0.40 - w * 0.16, y: h * 0.35 - w * 0.16,
                    width: w * 0.32, height: w * 0.32
                )),
                with: .color(primary.opacity(0.28))
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: w * 0.58 - w * 0.22, y: h * 0.32 - w * 0.22,
                    width: w * 0.44, height: w * 0.44
                )),
                with: .color(primary.opacity(0.28))
            )
            context.fill(
                Path(roundedRect: CGRect(
                    x: w * 0.32, y: h * 0.36, width: w * 0.42, height: h * 0.14
                ), cornerRadius: w * 0.06),
                with: .color(primary.opacity(0.28))
            )

            // 向下箭头
            context.fill(
                Path(roundedRect: CGRect(
                    x: w * 0.475, y: h * 0.48, width: w * 0.05, height: h * 0.28
                ), cornerRadius: w * 0.025),
                with: .color(primary)
            )
            context.fill(
                Path(roundedRect: CGRect(
                    x: w * 0.40, y: h * 0.70, width: w * 0.20, height: h * 0.05
                ), cornerRadius: w * 0.02),
                with: .color(primary)
            )

            context.fill(
                Path(ellipseIn: CGRect(
                    x: w * 0.78 - w * 0.021, y: h * 0.41 - w * 0.021,
                    width: w * 0.042, height: w * 0.042
                )),
                with: .color(Color.white.opacity(0.9))
            )
        }
        .frame(width: 152, height: 122)
    }
}

/// 空状态插画：搜索放大镜。
struct SearchIllustration: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let primary = Aurora.brand

            context.fill(
                Path(ellipseIn: CGRect(
                    x: w * 0.5 - w * 0.42, y: h * 0.52 - w * 0.42,
                    width: w * 0.84, height: w * 0.84
                )),
                with: .color(primary.opacity(0.07))
            )

            let ring = Path(ellipseIn: CGRect(
                x: w * 0.46 - w * 0.20, y: h * 0.44 - w * 0.20,
                width: w * 0.40, height: w * 0.40
            ))
            context.stroke(ring, with: .color(Color.white), lineWidth: w * 0.05)
            context.stroke(ring, with: .color(primary), lineWidth: w * 0.035)

            context.fill(
                Path(roundedRect: CGRect(
                    x: w * 0.62, y: h * 0.58, width: w * 0.24, height: h * 0.055
                ), cornerRadius: w * 0.028),
                with: .color(primary)
            )
        }
        .frame(width: 152, height: 122)
    }
}

/// 空状态插画：文件列表。
struct FileListIllustration: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let primary = Aurora.brand

            context.fill(
                Path(ellipseIn: CGRect(
                    x: w * 0.5 - w * 0.42, y: h * 0.52 - w * 0.42,
                    width: w * 0.84, height: w * 0.84
                )),
                with: .color(primary.opacity(0.07))
            )

            context.fill(
                Path(roundedRect: CGRect(
                    x: w * 0.14, y: h * 0.22, width: w * 0.58, height: h * 0.20
                ), cornerRadius: w * 0.04),
                with: .color(primary)
            )
            context.fill(
                Path(roundedRect: CGRect(
                    x: w * 0.14, y: h * 0.48, width: w * 0.58, height: h * 0.20
                ), cornerRadius: w * 0.04),
                with: .color(primary.opacity(0.55))
            )
            context.fill(
                Path(roundedRect: CGRect(
                    x: w * 0.14, y: h * 0.74, width: w * 0.58, height: h * 0.20
                ), cornerRadius: w * 0.04),
                with: .color(primary.opacity(0.28))
            )

            context.fill(
                Path(ellipseIn: CGRect(
                    x: w * 0.78 - w * 0.021, y: h * 0.41 - w * 0.021,
                    width: w * 0.042, height: w * 0.042
                )),
                with: .color(Color.white.opacity(0.9))
            )
        }
        .frame(width: 152, height: 122)
    }
}

// MARK: - 通用空状态

/// 统一的空状态：圆角方块图标 + 标题 + 说明。
struct EmptyStateView<Action: View>: View {

    let systemIcon: String
    let title: String
    var message: String? = nil
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Aurora.brand.tint(0.10))
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: systemIcon)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(Aurora.brand)
                )
            Spacer().frame(height: 16)
            Text(title)
                .font(AuroraFont.titleLarge)
                .foregroundStyle(Aurora.ink)
            if let message {
                Spacer().frame(height: 4)
                Text(message)
                    .font(AuroraFont.bodySmall)
                    .foregroundStyle(Aurora.inkSoft)
                    .multilineTextAlignment(.center)
            }
            Spacer().frame(height: 14)
            action()
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(systemIcon: String, title: String, message: String? = nil) {
        self.init(systemIcon: systemIcon, title: title, message: message) { EmptyView() }
    }
}
