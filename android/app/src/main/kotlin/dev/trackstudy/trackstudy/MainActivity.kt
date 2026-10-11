package dev.trackstudy.trackstudy

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    private var exportResult: MethodChannel.Result? = null
    private var exportData: String? = null
    private val exportRequest = 4201

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.trackstudy/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "saveJson") { result.notImplemented(); return@setMethodCallHandler }
                if (exportResult != null) { result.error("busy", "An export is already open.", null); return@setMethodCallHandler }
                val data = call.argument<String>("data")
                val name = call.argument<String>("name")
                if (data == null || name == null) { result.error("invalid", "Missing export data.", null); return@setMethodCallHandler }
                exportResult = result
                exportData = data
                try {
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/json"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }, exportRequest)
                } catch (_: Exception) {
                    exportResult = null; exportData = null
                    result.error("unavailable", "Android could not open the document picker.", null)
                }
            }
    }

    @Deprecated("Required by FlutterActivity's activity result dispatch")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != exportRequest) return
        val result = exportResult ?: return
        val json = exportData
        exportResult = null; exportData = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || json == null) { result.success(false); return }
        thread {
            try {
                val output = contentResolver.openOutputStream(uri, "wt") ?: error("Document unavailable")
                output.bufferedWriter(Charsets.UTF_8).use { it.write(json) }
                runOnUiThread { result.success(true) }
            } catch (_: Exception) {
                runOnUiThread { result.error("write_failed", "The selected document could not be written.", null) }
            }
        }
    }
}
