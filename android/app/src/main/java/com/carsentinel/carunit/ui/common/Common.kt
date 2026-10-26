package com.carsentinel.carunit.ui.common

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carsentinel.carunit.ui.theme.AppTheme

// === Aurora UI 通用组件（复制到新项目后只需改 package）===

/** 极光背景：近白底 + 三团很淡的径向色晕，给实白卡片提供层次，但不抢内容 */
@Composable
fun AuroraBackdrop(modifier: Modifier = Modifier) {
    val scheme = MaterialTheme.colorScheme
    val bg = scheme.background
    val primary = scheme.primary
    val secondary = scheme.secondary
    val rose = scheme.tertiary
    Canvas(modifier.fillMaxSize()) {
        drawRect(bg)
        drawRect(
            Brush.radialGradient(
                listOf(primary.copy(alpha = 0.11f), Color.Transparent),
                center = Offset(size.width * 0.16f, size.height * 0.02f),
                radius = size.width * 0.85f
            )
        )
        drawRect(
            Brush.radialGradient(
                listOf(secondary.copy(alpha = 0.08f), Color.Transparent),
                center = Offset(size.width * 1.04f, size.height * 0.68f),
                radius = size.width * 0.8f
            )
        )
        drawRect(
            Brush.radialGradient(
                listOf(rose.copy(alpha = 0.05f), Color.Transparent),
                center = Offset(size.width * 0.02f, size.height * 0.98f),
                radius = size.width * 0.7f
            )
        )
    }
}

/**
 * 与白色按比例混合，得到**不透明**的浅色底。
 * 半透明色铺在阴影上方会让阴影透出来，看起来像“底下叠了一块灰方块”，所以统一用实色。
 */
fun Color.tint(strength: Float): Color = lerp(Color.White, this, strength)

/** 按下时轻微缩放，给卡片一点“实体感” */
fun Modifier.pressScale(
    source: MutableInteractionSource,
    pressedScale: Float = 0.982f
): Modifier = composed {
    val pressed by source.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed) pressedScale else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessMediumLow),
        label = "pressScale"
    )
    graphicsLayer {
        scaleX = scale
        scaleY = scale
    }
}

/** 自绘顶栏，替代系统 ActionBar */
@Composable
fun AppTopBar(
    title: String,
    subtitle: String? = null,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {}
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(start = if (onBack == null) 20.dp else 4.dp, end = 10.dp, top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (onBack != null) {
            IconButton(onClick = onBack, modifier = Modifier.size(44.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "返回",
                    tint = MaterialTheme.colorScheme.onBackground
                )
            }
            Spacer(Modifier.width(2.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = if (onBack == null) MaterialTheme.typography.headlineSmall else MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onBackground,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (subtitle != null) {
                Spacer(Modifier.height(2.dp))
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2
                )
            }
        }
        actions()
    }
}

/**
 * 底部悬浮操作条：实白底 + 细描边 + 柔化投影。
 * 不要改成半透明：半透明底会把阴影透上来，看起来像多垫了一层灰方块。
 */
@Composable
fun GlassBar(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(horizontal = 12.dp, vertical = 12.dp),
    content: @Composable ColumnScope.() -> Unit
) {
    val shape = RoundedCornerShape(26.dp)
    Column(
        modifier = modifier
            .shadow(
                elevation = 10.dp,
                shape = shape,
                clip = false,
                ambientColor = Color(0x14101628),
                spotColor = Color(0x1A101628)
            )
            .clip(shape)
            .background(Color.White)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f), shape)
            // 吞掉落在空白处的点击：否则会穿透到下面的列表项
            .pointerInput(Unit) { detectTapGestures { } }
            .padding(contentPadding),
        content = content
    )
}

/** 内容卡片：实白、20dp 圆角、1dp 描边、1dp 阴影 */
@Composable
fun SectionCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White),
        border = BorderStroke(
            1.dp,
            MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.55f)
        ),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
    ) {
        Column(Modifier.padding(16.dp), content = content)
    }
}

/**
 * 主操作按钮：品牌渐变底 + 居中白字。
 * 文字就是一个居中的 label，不另建 HStack 去挤。
 */
@Composable
fun GradientButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    leading: (@Composable () -> Unit)? = null
) {
    val extra = AppTheme.colors
    val shape = RoundedCornerShape(16.dp)
    val source = remember { MutableInteractionSource() }
    val btnAlpha by animateFloatAsState(
        targetValue = if (enabled) 1f else 0.45f,
        label = "btnAlpha"
    )
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(50.dp)
            .graphicsLayer { this.alpha = btnAlpha }
            .clip(shape)
            .background(
                Brush.horizontalGradient(
                    if (enabled) extra.brandGradient
                    else listOf(extra.muted, extra.muted)
                )
            )
            .pressScale(source)
            .clickable(
                interactionSource = source,
                indication = null,
                enabled = enabled,
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            if (leading != null) {
                leading()
                Spacer(Modifier.width(8.dp))
            }
            Text(
                text,
                style = MaterialTheme.typography.labelLarge,
                color = Color.White,
                maxLines = 1
            )
        }
    }
}

/** 次级按钮：实白底 + 细描边，用于「复制 announce」这类非主操作 */
@Composable
fun QuietButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true
) {
    val shape = RoundedCornerShape(14.dp)
    val source = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp)
            .clip(shape)
            .background(Color.White)
            .border(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.7f), shape)
            .pressScale(source)
            .clickable(
                interactionSource = source,
                indication = null,
                enabled = enabled,
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelLarge,
            color = if (enabled) MaterialTheme.colorScheme.primary
            else MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1
        )
    }
}

/** 状态胶囊：小圆点 + 文字，可点击查看详情 */
@Composable
fun StatusPill(
    text: String,
    color: Color,
    modifier: Modifier = Modifier,
    onClick: (() -> Unit)? = null
) {
    val shape = CircleShape
    Row(
        modifier = modifier
            .clip(shape)
            .background(color.tint(0.13f))
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 9.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(color))
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            color = color,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

/** 首字圆角方块，代替图标，避免“纯文字工程感” */
@Composable
fun Monogram(name: String, tint: Color, size: Int = 44) {
    val letter = name.trim().take(1).ifBlank { "P" }
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(tint.tint(0.13f)),
        contentAlignment = Alignment.Center
    ) {
        Text(
            letter,
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = tint
        )
    }
}

/** 空状态插画：圆角几何图形，纯 Canvas 绘制，不增加包体。可按业务替换形状。 */
@Composable
fun PrinterIllustration(modifier: Modifier = Modifier) {
    val primary = MaterialTheme.colorScheme.primary
    Canvas(modifier.size(width = 152.dp, height = 122.dp)) {
        val w = size.width
        val h = size.height
        drawCircle(primary.copy(alpha = 0.07f), radius = w * 0.42f, center = Offset(w * 0.5f, h * 0.52f))
        drawRoundRect(
            Color.White, Offset(w * 0.31f, h * 0.05f), Size(w * 0.38f, h * 0.30f), CornerRadius(w * 0.022f)
        )
        drawRoundRect(
            primary.copy(alpha = 0.28f), Offset(w * 0.36f, h * 0.12f), Size(w * 0.28f, h * 0.021f), CornerRadius(w * 0.011f)
        )
        drawRoundRect(
            primary.copy(alpha = 0.16f), Offset(w * 0.36f, h * 0.18f), Size(w * 0.20f, h * 0.021f), CornerRadius(w * 0.011f)
        )
        drawRoundRect(
            primary, Offset(w * 0.13f, h * 0.35f), Size(w * 0.74f, h * 0.31f), CornerRadius(w * 0.065f)
        )
        drawRoundRect(
            Color.White.copy(alpha = 0.92f), Offset(w * 0.23f, h * 0.54f), Size(w * 0.54f, h * 0.055f),
            CornerRadius(w * 0.027f)
        )
        drawRoundRect(
            Color.White, Offset(w * 0.27f, h * 0.59f), Size(w * 0.46f, h * 0.30f), CornerRadius(w * 0.03f)
        )
        drawRoundRect(
            primary.copy(alpha = 0.22f), Offset(w * 0.33f, h * 0.67f), Size(w * 0.34f, h * 0.021f), CornerRadius(w * 0.011f)
        )
        drawRoundRect(
            primary.copy(alpha = 0.13f), Offset(w * 0.33f, h * 0.74f), Size(w * 0.26f, h * 0.021f), CornerRadius(w * 0.011f)
        )
        drawCircle(Color.White.copy(alpha = 0.9f), radius = w * 0.021f, center = Offset(w * 0.78f, h * 0.41f))
    }
}

/** 状态等级 → 颜色。1 进行中 / 2 正常 / 3 提醒 / 4 失败 */
@Composable
fun statusColor(level: Int): Color {
    val extra = AppTheme.colors
    return when (level) {
        1 -> extra.info
        2 -> extra.success
        3 -> extra.warning
        4 -> MaterialTheme.colorScheme.error
        else -> extra.muted
    }
}
