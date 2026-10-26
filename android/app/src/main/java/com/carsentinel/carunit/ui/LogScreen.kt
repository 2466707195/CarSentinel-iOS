package com.carsentinel.carunit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carsentinel.carunit.net.LogEntry
import com.carsentinel.carunit.net.LogLevel
import com.carsentinel.carunit.ui.common.AppTopBar
import com.carsentinel.carunit.ui.common.AuroraBackdrop
import com.carsentinel.carunit.ui.common.SectionCard
import com.carsentinel.carunit.ui.common.StatusPill
import com.carsentinel.carunit.ui.common.tint
import com.carsentinel.carunit.ui.theme.AppTheme

/**
 * 日志页：显示 `log` 条目，与控制通道推给手机的 `{"t":"log"}` 同源。
 */
@Composable
fun LogScreen(
    logs: List<LogEntry>,
    modifier: Modifier = Modifier
) {
    val extra = AppTheme.colors
    val listState = rememberLazyListState()

    Box(modifier.fillMaxSize()) {
        AuroraBackdrop(Modifier.fillMaxSize())
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 14.dp, end = 14.dp, top = 4.dp, bottom = 152.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            item {
                AppTopBar(
                    title = "运行日志",
                    subtitle = "与控制通道推送的 log 同源 · 共 ${logs.size} 条"
                )
            }

            if (logs.isEmpty()) {
                item {
                    SectionCard {
                        Text(
                            "暂无日志",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "启动推流服务后，这里会显示摄像头枚举、连接与异常。",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                items(logs.asReversed()) { entry ->
                    SectionCard {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                formatTime(entry.atMs),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Spacer(Modifier.weight(1f))
                            StatusPill(
                                text = levelLabel(entry.level),
                                color = levelColor(entry.level)
                            )
                        }
                        Spacer(Modifier.height(6.dp))
                        Text(
                            entry.msg,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun levelColor(level: LogLevel): Color {
    // AppTheme.colors 是 @Composable getter，所以本函数也必须是 @Composable
    val extra = AppTheme.colors
    return when (level) {
        LogLevel.error -> extra.danger
        LogLevel.warn -> extra.warning
        LogLevel.debug -> extra.muted
        LogLevel.info -> extra.info
    }
}

private fun levelLabel(level: LogLevel): String = when (level) {
    LogLevel.error -> "错误"
    LogLevel.warn -> "警告"
    LogLevel.debug -> "调试"
    LogLevel.info -> "信息"
}

private fun formatTime(atMs: Long): String {
    val sdf = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US)
    return sdf.format(java.util.Date(atMs))
}
