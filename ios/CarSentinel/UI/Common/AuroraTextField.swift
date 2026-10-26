import SwiftUI
import UIKit

/// Aurora UI 输入框：白底、14pt 圆角、聚焦时品牌色描边。
///
/// 对应 Material 的 `OutlinedTextField`。
struct AuroraTextField: View {

    let placeholder: String
    @Binding var text: String
    var systemIcon: String? = nil
    var trailingSystemIcon: String? = nil
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var onTrailingTap: (() -> Void)? = nil

    @FocusState var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(Aurora.inkSoft)
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(AuroraFont.bodyMedium)
                        .foregroundStyle(Aurora.muted)
                        .allowsHitTesting(false)
                }
                field
            }
            .focused($isFocused)

            if let trailingSystemIcon {
                Button {
                    onTrailingTap?()
                } label: {
                    Image(systemName: trailingSystemIcon)
                        .font(.system(size: 15))
                        .foregroundStyle(Aurora.inkSoft)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity)
        .background(AuroraShape.control.fill(Color.white))
        .overlay(
            AuroraShape.control.stroke(isFocused ? Aurora.brand : Aurora.line, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField("", text: $text)
                .font(AuroraFont.bodyMedium)
                .foregroundStyle(Aurora.ink)
        } else {
            TextField("", text: $text)
                .font(AuroraFont.bodyMedium)
                .foregroundStyle(Aurora.ink)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}
