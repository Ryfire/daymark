package com.ryfire.daymark

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Hosts the Flutter engine and bridges share-sheet intake. Incoming
/// ACTION_SEND payloads are buffered natively; Dart pulls via `takeIncoming`
/// on start and on every resume, which avoids push/listen races entirely.
class MainActivity : FlutterActivity() {
    private var pending: Map<String, Any?>? = null
    private var channel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pending = extractPayload(intent) ?: pending
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "daymark/incoming",
        )
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeIncoming" -> {
                    val payload = pending
                    pending = null
                    result.success(payload)
                }
                "readStream" -> {
                    val uri = Uri.parse(call.arguments as String)
                    try {
                        val stream = contentResolver.openInputStream(uri)
                        if (stream == null) {
                            result.error("unreadable", "No stream for $uri", null)
                        } else {
                            stream.use { result.success(it.readBytes()) }
                        }
                    } catch (e: Exception) {
                        result.error("unreadable", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pending = extractPayload(intent) ?: pending
    }

    private fun extractPayload(intent: Intent?): Map<String, Any?>? {
        if (intent?.action != Intent.ACTION_SEND) return null
        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        return mapOf(
            "stream" to uri?.toString(),
            "text" to intent.getStringExtra(Intent.EXTRA_TEXT),
            "mimeType" to intent.type,
        )
    }
}
