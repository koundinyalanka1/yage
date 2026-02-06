package com.yourmateapps.retropal

import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.yourmateapps.retropal/device"
    private var pendingFilePath: String? = null
    private var permissionResultHandler: ((Boolean) -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> {
                        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                        val isTV = uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                        result.success(isTV)
                    }
                    "getOpenFilePath" -> {
                        // Return any file path from an incoming VIEW intent
                        val path = pendingFilePath
                        pendingFilePath = null
                        result.success(path)
                    }
                    "requestStoragePermission" -> {
                        requestStoragePermission { granted ->
                            result.success(granted)
                        }
                    }
                    "hasStoragePermission" -> {
                        result.success(hasStoragePermission())
                    }
                    else -> result.notImplemented()
                }
            }

        // Handle intent that launched/resumed the activity
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_VIEW) {
            val uri = intent.data ?: return
            val path = resolveUriToPath(uri)
            if (path != null) {
                pendingFilePath = path
            }
        }
    }

    /**
     * Resolve a content:// or file:// URI to an actual filesystem path.
     * For content:// URIs, copies the file to app cache so the native
     * emulator core can read it directly.
     */
    private fun resolveUriToPath(uri: Uri): String? {
        // file:// scheme — direct path
        if (uri.scheme == "file") {
            return uri.path
        }

        // content:// scheme — need to copy to cache
        if (uri.scheme == "content") {
            try {
                val fileName = getFileName(uri) ?: "rom_${System.currentTimeMillis()}"
                val cacheDir = File(cacheDir, "opened_roms")
                cacheDir.mkdirs()
                val destFile = File(cacheDir, fileName)

                contentResolver.openInputStream(uri)?.use { input ->
                    destFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                return destFile.absolutePath
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        return null
    }

    private fun getFileName(uri: Uri): String? {
        var name: String? = null
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val nameIndex = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (nameIndex >= 0 && cursor.moveToFirst()) {
                name = cursor.getString(nameIndex)
            }
        }
        return name
    }

    // ── Storage permission handling ──

    private fun hasStoragePermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestStoragePermission(callback: (Boolean) -> Unit) {
        if (hasStoragePermission()) {
            callback(true)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+: request MANAGE_EXTERNAL_STORAGE via Settings
            permissionResultHandler = callback
            try {
                val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
                startActivityForResult(intent, STORAGE_PERMISSION_CODE)
            } catch (_: Exception) {
                // Fallback if the specific intent is not available
                try {
                    val intent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                    startActivityForResult(intent, STORAGE_PERMISSION_CODE)
                } catch (_: Exception) {
                    callback(false)
                }
            }
        } else {
            // Android 10 and below
            permissionResultHandler = callback
            ActivityCompat.requestPermissions(
                this,
                arrayOf(
                    android.Manifest.permission.READ_EXTERNAL_STORAGE,
                    android.Manifest.permission.WRITE_EXTERNAL_STORAGE
                ),
                STORAGE_PERMISSION_CODE
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == STORAGE_PERMISSION_CODE) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            permissionResultHandler?.invoke(granted)
            permissionResultHandler = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == STORAGE_PERMISSION_CODE) {
            // Check if permission was granted after returning from Settings
            val granted = hasStoragePermission()
            permissionResultHandler?.invoke(granted)
            permissionResultHandler = null
        }
    }

    companion object {
        private const val STORAGE_PERMISSION_CODE = 1001
    }
}
