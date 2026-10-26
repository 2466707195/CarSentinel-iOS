package com.carsentinel.carunit.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// === Aurora UI 设计 token（改包名后即可使用）===

private val Brand = Color(0xFF4F46E5)
private val BrandDeep = Color(0xFF3730C0)
private val Teal = Color(0xFF0F9D9D)
private val Rose = Color(0xFFD6336C)
private val CanvasBg = Color(0xFFF8F7FC)
private val Ink = Color(0xFF17171F)
private val InkSoft = Color(0xFF5C5C70)
private val Line = Color(0xFFE7E5F0)

private val AppLightColors = lightColorScheme(
    primary = Brand,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE5E2FF),
    onPrimaryContainer = Color(0xFF1B1464),
    secondary = Teal,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFCAF2F1),
    onSecondaryContainer = Color(0xFF003737),
    tertiary = Rose,
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFD9E3),
    onTertiaryContainer = Color(0xFF3E0021),
    background = CanvasBg,
    onBackground = Ink,
    surface = Color.White,
    onSurface = Ink,
    surfaceVariant = Color(0xFFEFEDF7),
    onSurfaceVariant = InkSoft,
    outline = Color(0xFFC6C3D6),
    outlineVariant = Line,
    error = Color(0xFFC62828),
    onError = Color.White,
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
    inverseSurface = Color(0xFF2F2F38),
    inverseOnSurface = Color(0xFFF3F0FA),
    surfaceTint = Brand,
    scrim = Color(0x99101018)
)

/** Material 3 之外额外需要的语义色：成功/警告/信息/中性/描边/品牌渐变 */
@Immutable
data class AppExtraColors(
    val success: Color = Color(0xFF11875A),
    val successContainer: Color = Color(0xFFD8F5E8),
    val warning: Color = Color(0xFFB26A00),
    // 注意：这一行原来是 `val warningContainer: Color(0xFFFFEDCB)`，少了个 `=`，
    // 是 Aurora UI 资产里带过来的语法错误。它会让整个 data class 解析失败，
    // 于是 AppTheme.colors.* 全部 unresolved —— 一个等号炸出 14 个错。
    val warningContainer: Color = Color(0xFFFFEDCB),
    val info: Color = Color(0xFF2563EB),
    // 同一类漏 `=`：原来是 `val infoContainer: Color(0xFFDDE8FF)`
    val infoContainer: Color = Color(0xFFDDE8FF),
    // 品牌浅底 + 其上的文字色，给「启动推流」这类次按钮用
    val brandContainer: Color = Color(0xFFE5E2FF),
    val onBrandContainer: Color = Color(0xFF1B1464),
    val muted: Color = Color(0xFF8A8AA0),
    val hairline: Color = Color(0xFFEFEDF6),
    val danger: Color = Color(0xFFC62828),
    val dangerContainer: Color = Color(0xFFFFE0E0),
    val brandGradient: List<Color> = listOf(Color(0xFF5B54F0), Color(0xFF8B5CF6))
)

val LocalAppColors = staticCompositionLocalOf { AppExtraColors() }

/** 用法：AppTheme.colors.success */
object AppTheme {
    val colors: AppExtraColors
        @Composable get() = LocalAppColors.current
}

private val AppTypography = Typography(
    headlineMedium = TextStyle(
        fontWeight = FontWeight.Bold, fontSize = 28.sp, lineHeight = 34.sp, letterSpacing = (-0.5).sp
    ),
    headlineSmall = TextStyle(
        fontWeight = FontWeight.Bold, fontSize = 24.sp, lineHeight = 30.sp, letterSpacing = (-0.35).sp
    ),
    titleLarge = TextStyle(
        fontWeight = FontWeight.Bold, fontSize = 19.sp, lineHeight = 25.sp, letterSpacing = (-0.15).sp
    ),
    titleMedium = TextStyle(
        fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 22.sp
    ),
    titleSmall = TextStyle(
        fontWeight = FontWeight.SemiBold, fontSize = 14.sp, lineHeight = 20.sp
    ),
    bodyLarge = TextStyle(fontSize = 15.sp, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 20.sp),
    bodySmall = TextStyle(fontSize = 12.5.sp, lineHeight = 18.sp),
    labelLarge = TextStyle(
        fontWeight = FontWeight.SemiBold, fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = 0.1.sp
    ),
    labelMedium = TextStyle(
        fontWeight = FontWeight.SemiBold, fontSize = 12.sp, lineHeight = 16.sp, letterSpacing = 0.2.sp
    ),
    labelSmall = TextStyle(
        fontWeight = FontWeight.Medium, fontSize = 11.sp, lineHeight = 14.sp, letterSpacing = 0.3.sp
    )
)

private val AppShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(12.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp)
)

/** 主题入口。复制到新项目时把 AuroraTheme 改名成 <项目名>Theme 即可。 */
@Composable
fun CarSentinelTheme(content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalAppColors provides AppExtraColors()) {
        MaterialTheme(
            colorScheme = AppLightColors,
            typography = AppTypography,
            shapes = AppShapes,
            content = content
        )
    }
}
