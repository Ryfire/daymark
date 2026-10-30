package com.ryfire.daymark

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Hosts the Flutter engine and bridges share-sheet intake. Incoming
/// ACTION_SEND payloads are buffered natively; Dart pulls via `takeIncoming`
/// on start and on every resume, which avoids push/listen races entirely.
///
/// The second channel (`daymark/outgoing`) covers everything Daymark sends
/// back out: rewritten notes handed to JotLock through its package-targeted
/// share filter (jotlock opens its editor pre-filled and the user confirms),
/// the app version for the About page, and https/http links for the browser.
class MainActivity : FlutterActivity() {
    private var pending: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        pending = extractPayload(intent) ?: pending
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "daymark/incoming",
        ).setMethodCallHandler { call, result ->
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "daymark/outgoing",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sendNote" -> {
                    val text = call.argument<String>("text")?.trim().orEmpty()
                    if (text.isEmpty()) {
                        result.error("invalid", "Note text is empty", null)
                    } else {
                        val share = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, text)
                            // JotLock only: skips the system chooser and lands
                            // in its editor pre-filled for one-tap confirmation.
                            setPackage("com.ryfire.jotlock")
                            // Own task for JotLock: without NEW_TASK its editor
                            // stacks on top of Daymark inside Daymark's task,
                            // and tapping Daymark's launcher icon later just
                            // re-fronts that task with JotLock showing. NEW_TASK
                            // (jotlock's MainActivity declares an empty
                            // taskAffinity, so no unrelated task matches) keeps
                            // the two apps separate; Daymark stays reachable.
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        try {
                            startActivity(share)
                            result.success(true)
                        } catch (e: ActivityNotFoundException) {
                            result.error("no_jotlock", "JotLock is not installed", null)
                        }
                    }
                }
                "openUrl" -> {
                    val url = call.argument<String>("url").orEmpty()
                    val opened = if (url.startsWith("https://") ||
                        url.startsWith("http://")
                    ) {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            true
                        } catch (e: Exception) {
                            false
                        }
                    } else {
                        false
                    }
                    result.success(opened)
                }
                "getVersionName" -> result.success(
                    try {
                        packageManager.getPackageInfo(packageName, 0).versionName
                    } catch (e: Exception) {
                        ""
                    }
                )
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
