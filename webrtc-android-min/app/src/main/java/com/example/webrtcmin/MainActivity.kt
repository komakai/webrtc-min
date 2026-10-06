package com.example.webrtcmin

import android.Manifest
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.edit
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.PeerConnectionFactory
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer

// Two screens: home, with a button for each room and a settings icon for the
// server, and the call, with the other user's video, ours in a corner, and
// mute and hang-up buttons.
class MainActivity : ComponentActivity() {
    private val prefs by lazy { getSharedPreferences("settings", MODE_PRIVATE) }
    private val eglBase = EglBase.create()
    private lateinit var factory: PeerConnectionFactory
    private lateinit var localRenderer: SurfaceViewRenderer
    private lateinit var remoteRenderer: SurfaceViewRenderer

    private var server by mutableStateOf("")
    private var status by mutableStateOf("")
    private var call by mutableStateOf<Call?>(null)
    private var muted by mutableStateOf(false)
    private var settingsOpen by mutableStateOf(false)
    private var room = 0 // The room being entered, while the permissions are asked for.

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (it.values.all { granted -> granted }) enter()
        else status = "The camera and microphone permissions are needed (see Settings > Apps)"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Draws behind transparent system bars, with light icons, on every
        // Android version (only 15 and later do it by default).
        val transparent = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT)
        enableEdgeToEdge(transparent, transparent)
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        server = prefs.getString("server", null) ?: "192.168.11.12:8080"

        PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(this).createInitializationOptions())
        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .createPeerConnectionFactory()
        remoteRenderer = SurfaceViewRenderer(this).apply {
            init(eglBase.eglBaseContext, null)
            setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        }
        localRenderer = SurfaceViewRenderer(this).apply {
            init(eglBase.eglBaseContext, null)
            setMirror(true)
            setZOrderMediaOverlay(true)
        }

        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Box(Modifier.fillMaxSize().background(Color.Black)) {
                    if (call == null) Home() else CallScreen()
                    if (settingsOpen) Settings()
                }
            }
        }
    }

    @Composable
    private fun BoxScope.Home() {
        IconButton({ settingsOpen = true }, Modifier.align(Alignment.TopEnd).safeDrawingPadding().padding(8.dp)) {
            Icon(painterResource(R.drawable.ic_settings), "Settings", tint = Color.White)
        }
        Column(Modifier.align(Alignment.Center), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            for (n in 1..4) {
                Button(
                    {
                        room = n
                        permissions.launch(arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO))
                    },
                    Modifier.width(160.dp),
                ) {
                    Text("Room $n")
                }
            }
        }
        Text(
            status,
            Modifier.align(Alignment.BottomCenter).safeDrawingPadding().padding(32.dp),
            Color.White,
            textAlign = TextAlign.Center,
        )
    }

    @Composable
    private fun BoxScope.CallScreen() {
        AndroidView({ remoteRenderer }, Modifier.fillMaxSize())
        AndroidView(
            { localRenderer },
            Modifier.align(Alignment.TopEnd).safeDrawingPadding().padding(16.dp).size(96.dp, 128.dp),
        )
        Column(
            Modifier.align(Alignment.BottomCenter).safeDrawingPadding().padding(32.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(status, color = Color.White, textAlign = TextAlign.Center)
            Row(horizontalArrangement = Arrangement.spacedBy(48.dp)) {
                FloatingActionButton(
                    {
                        muted = !muted
                        call?.setMuted(muted)
                    },
                    shape = CircleShape,
                    containerColor = if (muted) Color.White else Color.DarkGray,
                ) {
                    Icon(
                        painterResource(if (muted) R.drawable.ic_mic_off else R.drawable.ic_mic),
                        if (muted) "Unmute" else "Mute",
                        tint = if (muted) Color.Black else Color.White,
                    )
                }
                FloatingActionButton({ call?.stop() }, shape = CircleShape, containerColor = Color(0xFFD32F2F)) {
                    Icon(painterResource(R.drawable.ic_call_end), "Hang up", tint = Color.White)
                }
            }
        }
    }

    @Composable
    private fun Settings() {
        var draft by remember { mutableStateOf(server) }
        AlertDialog(
            onDismissRequest = { settingsOpen = false },
            confirmButton = {
                TextButton({
                    server = draft.trim()
                    prefs.edit { putString("server", server) }
                    settingsOpen = false
                }) { Text("OK") }
            },
            dismissButton = { TextButton({ settingsOpen = false }) { Text("Cancel") } },
            title = { Text("Settings") },
            text = {
                OutlinedTextField(
                    draft, { draft = it },
                    label = { Text("stun-room server (host:port)") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                )
            },
        )
    }

    private fun enter() {
        muted = false
        call = Call(
            this, factory, eglBase, server, room, localRenderer, remoteRenderer,
            onStatus = { runOnUiThread { status = it } },
            onEnd = { runOnUiThread { call = null; localRenderer.clearImage() } },
        )
    }

    override fun onDestroy() {
        call?.stop()
        super.onDestroy()
    }
}
