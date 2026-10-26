package com.carsentinel.carunit.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.carsentinel.carunit.net.Protocol
import com.carsentinel.carunit.service.ServiceController
import com.carsentinel.carunit.ui.common.AppTopBar
import com.carsentinel.carunit.ui.common.AuroraBackdrop
import com.carsentinel.carunit.ui.common.GradientButton
import com.carsentinel.carunit.ui.common.QuietButton
import com.carsentinel.carunit.ui.common.SectionCard
import com.carsentinel.carunit.ui.common.StatusPill
import com.carsentinel.carunit.ui.common.tint
import com.carsentinel.carunit.ui.theme.AppTheme

/**
 * 状态页：服务开关 / 设备名 / 局域网地址 / 每路摄像头 / 总带宽 / 复制 announce。
 */
@Composable
fun StatusScreen(
    state: ServiceController.UiState,
    onToggleService: (Boolean) -> Unit,
    modifier: Modifier = Modifier
) {
    val extra = AppTheme.colors
    val context = LocalContext.current
    val listState = rememberLazyListState()
    var toast by remember { mutableStateOf<String?>(null) }

    Box(modifier.fillMaxSize()) {
        AuroraBackdrop(Modifier.fillMaxSize())
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 14.dp, end = 14.dp, top = 4.dp, bottom = 152.dp
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            item {
                AppTopBar(
                    title = "车载哨兵",
                    subtitle = "CarSentinel 360 · 车机端"
                )
            }

            // ---- 服务卡片 ----
            item {
                SectionCard {
                    Text(
                        "推流服务",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        if (state.running) "运行中 · 手机可在同一局域网发现本机"
                        else "已停止 · 启动后开始采集并推流",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(Modifier.height(12.dp))
                    GradientButton(
                        text = if (state.running) "停止推流" else "启动推流",
                        onClick = { onToggleService(!state.running) }
                    )
                    Spacer(Modifier.height(14.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "设备名",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.width(72.dp)
                        )
                        Text(
                            state.deviceName,
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "服务地址",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.width(72.dp)
                        )
                        Text(
                            "${state.ip}:${state.port}",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.primary
                        )
                        Spacer(Modifier.width(8.dp))
                        StatusPill(
                            text = "TCP ${Protocol.TCP_PORT}",
                            color = if (state.running) extra.success else extra.muted
                        )
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "运行时长",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.width(72.dp)
                        )
                        Text(
                            formatUptime(state.uptimeSec),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Spacer(Modifier.width(12.dp))
                        Text(
                            "CPU ${percent(state.cpu)}",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            // ---- 摄像头卡片们 ----
            if (state.cameras.isEmpty()) {
                item {
                    SectionCard {
                        Text(
                            "摄像头",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            if (state.running) "尚未打开任何摄像头，正在重试…" else "服务未启动",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                items(state.cameras, key = { it.id }) { cam ->
                    SectionCard {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(
                                    cam.name,
                                    style = MaterialTheme.typography.titleLarge,
                                    color = MaterialTheme.colorScheme.onSurface
                                )
                                Spacer(Modifier.height(2.dp))
                                Text(
                                    "摄像头 ${cam.id} · ${Protocol.posName(cam.pos)}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                            StatusPill(
                                text = if (cam.active) "推流中" else "不可用",
                                color = if (cam.active) extra.success else extra.warning
                            )
                        }
                        Spacer(Modifier.height(10.dp))
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            InfoPill("${cam.w}×${cam.h}")
                            InfoPill("${cam.fps} fps")
                            InfoPill("${cam.kbps} kbps")
                            InfoPill(cam.pos, tint = extra.info)
                        }
                    }
                }
            }

            // ---- 总带宽 ----
            item {
                SectionCard {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(
                                "总带宽",
                                style = MaterialTheme.typography.titleMedium,
                                color = MaterialTheme.colorScheme.onSurface
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                "${state.cameras.count { it.active }} 路 · ${Protocol.CODEC_H264.uppercase()}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Text(
                            "${state.totalKbps} kbps",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                    Spacer(Modifier.height(12.dp))
                    QuietButton(
                        text = "复制 announce JSON",
                        onClick = {
                            copyToClipboard(context, state.announceJson.ifBlank { "{}" })
                            toast = "已复制 announce JSON"
                        }
                    )
                    if (toast != null) {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            toast!!,
                            style = MaterialTheme.typography.bodySmall,
                            color = extra.success
                        )
                    }
                }
            }
        }
    }
}

/** 小信息胶囊，纯文字 */
@Composable
private fun InfoPill(text: String, tint: Color? = null) {
    val extra = AppTheme.colors
    val c = tint ?: extra.muted
    Box(
        Modifier
            .clip(RoundedCornerShape(9.dp))
            .background(c.tint(0.13f))
            .padding(horizontal = 8.dp, vertical = 4.dp)
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            color = c,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}

private fun percent(v: Double): String = "${(v * 100).toInt()}%"

private fun formatUptime(sec: Int): String {
    if (sec <= 0) return "—"
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%02d:%02d".format(m, s)
}

private fun copyToClipboard(context: Context, text: String) {
    try {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("CarSentinel announce", text))
    } catch (_: Throwable) {
    }
}
