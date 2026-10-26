package com.carsentinel.carunit

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.carsentinel.carunit.service.ServiceController
import com.carsentinel.carunit.ui.LogScreen
import com.carsentinel.carunit.ui.StatusScreen
import com.carsentinel.carunit.ui.common.AuroraBackdrop
import com.carsentinel.carunit.ui.common.GlassBar
import com.carsentinel.carunit.ui.theme.AppTheme
import com.carsentinel.carunit.ui.theme.CarSentinelTheme

class MainActivity : ComponentActivity() {

    private val requestPermissions =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        askPermissions()
        setContent {
            CarSentinelTheme {
                RootScaffold()
            }
        }
    }

    private fun askPermissions() {
        val need = ArrayList<String>()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
            != PackageManager.PERMISSION_GRANTED
        ) {
            need.add(Manifest.permission.CAMERA)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED
            ) {
                need.add(Manifest.permission.POST_NOTIFICATIONS)
            }
        }
        if (need.isNotEmpty()) {
            try {
                requestPermissions.launch(need.toTypedArray())
            } catch (_: Throwable) {
            }
        }
    }
}

private enum class Screen { Status, Log }

@Composable
fun RootScaffold() {
    val context = LocalContext.current
    val state by ServiceController.state.collectAsState()
    var screen by remember { mutableStateOf(Screen.Status) }

    Box(Modifier.fillMaxSize()) {
        AuroraBackdrop(Modifier.fillMaxSize())

        when (screen) {
            Screen.Status -> StatusScreen(
                state = state,
                onToggleService = { on ->
                    if (on) ServiceController.start(context)
                    else ServiceController.stop(context)
                },
                onRetryCameras = { ServiceController.retryCameras(context) },
                onRunProbe = { ServiceController.runProbe(context) }
            )

            Screen.Log -> LogScreen(logs = state.logs)
        }

        // 底部切换条：实白 + 26dp 圆角 + 10dp 投影 + 1dp 描边
        Box(
            Modifier
                .align(Alignment.BottomCenter)
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(start = 14.dp, end = 14.dp, bottom = 12.dp)
        ) {
            GlassBar {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TabButton(
                        text = "状态",
                        selected = screen == Screen.Status,
                        modifier = Modifier.weight(1f)
                    ) { screen = Screen.Status }
                    Spacer(Modifier.width(10.dp))
                    TabButton(
                        text = "日志",
                        selected = screen == Screen.Log,
                        modifier = Modifier.weight(1f)
                    ) { screen = Screen.Log }
                }
            }
        }
    }
}

@Composable
private fun TabButton(
    text: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    val extra = AppTheme.colors
    val bg = if (selected) extra.info else MaterialTheme.colorScheme.surfaceVariant
    val fg = if (selected) Color.White else MaterialTheme.colorScheme.onSurfaceVariant
    val source = remember { MutableInteractionSource() }

    Box(
        modifier = modifier
            .height(44.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .clickable(
                interactionSource = source,
                indication = null,
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelLarge,
            color = fg,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis
        )
    }
}
