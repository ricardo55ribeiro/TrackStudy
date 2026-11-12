package dev.trackstudy.trackstudy

import android.annotation.TargetApi
import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private class DocumentExport(
        val result: MethodChannel.Result,
        val canceled: Any?,
        val saved: (Uri) -> Any,
        val write: (OutputStream) -> Unit,
    )

    private var pendingExport: DocumentExport? = null
    private val exportRequest = 4201

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.trackstudy/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveJson" && call.method != "savePng") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val name = call.argument<String>("name")
                if (name.isNullOrBlank()) {
                    result.error("invalid", "Missing export filename.", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "saveJson" -> {
                        val data = call.argument<String>("data")
                        if (data == null) {
                            result.error("invalid", "Missing export data.", null)
                            return@setMethodCallHandler
                        }
                        createDocument(name, "application/json", DocumentExport(result, false, { true }) {
                            val writer = it.bufferedWriter(Charsets.UTF_8)
                            writer.write(data)
                            writer.flush()
                        })
                    }
                    "savePng" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data == null || data.isEmpty()) {
                            result.error("invalid", "Missing PNG data.", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            saveToDownloads(name, data, result)
                        } else {
                            createDocument(name, "image/png", DocumentExport(
                                result, null, { displayName(it) ?: name },
                            ) { it.write(data) })
                        }
                    }
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun createDocument(name: String, mimeType: String, export: DocumentExport) {
        if (pendingExport != null) {
            export.result.error("busy", "An export is already open.", null)
            return
        }
        pendingExport = export
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, name)
            }
            startActivityForResult(intent, exportRequest)
        } catch (_: Exception) {
            pendingExport = null
            export.result.error("unavailable", "Android could not open the document picker.", null)
        }
    }

    @Deprecated("Required by FlutterActivity's activity result dispatch")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != exportRequest) return
        val export = pendingExport ?: return
        pendingExport = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            export.result.success(export.canceled)
            return
        }
        thread {
            try {
                writeDocument(uri, export.write)
                val location = export.saved(uri)
                runOnUiThread { export.result.success(location) }
            } catch (_: Exception) {
                runOnUiThread {
                    export.result.error("write_failed", "The selected document could not be written.", null)
                }
            }
        }
    }

    private fun writeDocument(uri: Uri, write: (OutputStream) -> Unit) {
        val output = contentResolver.openOutputStream(uri, "wt") ?: error("Document unavailable")
        output.use(write)
    }

    private fun displayName(uri: Uri): String? = runCatching {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    }.getOrNull()

    @TargetApi(Build.VERSION_CODES.Q)
    private fun saveToDownloads(name: String, data: ByteArray, result: MethodChannel.Result) {
        thread {
            var pending: Uri? = null
            try {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, "image/png")
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                val downloads = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                val uri = contentResolver.insert(downloads, values)
                    ?: error("Downloads unavailable")
                pending = uri
                writeDocument(uri) { it.write(data) }
                val published = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                check(contentResolver.update(uri, published, null, null) == 1)
                val location = "Downloads/${displayName(uri) ?: name}"
                runOnUiThread { result.success(location) }
            } catch (_: Exception) {
                pending?.let { runCatching { contentResolver.delete(it, null, null) } }
                runOnUiThread { result.error("write_failed", "The PNG could not be saved to Downloads.", null) }
            }
        }
    }
}
