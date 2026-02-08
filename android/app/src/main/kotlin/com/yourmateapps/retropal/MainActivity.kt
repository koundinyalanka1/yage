package com.yourmateapps.retropal

import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.yourmateapps.retropal/device"
    private var pendingFilePath: String? = null

    // SAF folder import callback
    private var importRomsResultHandler: ((List<String>?) -> Unit)? = null

    // Legacy storage permission callback (Android ≤ 12 TV browser)
    private var permissionResultHandler: ((Boolean) -> Unit)? = null

    companion object {
        private const val SAF_IMPORT_FOLDER_CODE = 2001
        private const val STORAGE_PERMISSION_CODE = 1001
        private val ROM_EXTENSIONS = setOf("gba", "gb", "gbc", "sgb")
    }

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
                        val path = pendingFilePath
                        pendingFilePath = null
                        result.success(path)
                    }

                    // ── SAF-based folder import ──
                    // Opens the system folder picker, recursively scans for ROM files,
                    // copies them to internal storage, returns list of internal paths.
                    "importRomsFromFolder" -> {
                        importRomsResultHandler = { paths ->
                            result.success(paths)
                        }
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        startActivityForResult(intent, SAF_IMPORT_FOLDER_CODE)
                    }

                    // ── Internal ROM storage directory ──
                    "getInternalRomsDir" -> {
                        val romsDir = File(filesDir, "roms")
                        if (!romsDir.exists()) romsDir.mkdirs()
                        result.success(romsDir.absolutePath)
                    }

                    // ── Legacy: basic READ_EXTERNAL_STORAGE for TV browser (Android ≤ 12) ──
                    "hasStoragePermission" -> {
                        result.success(hasBasicReadPermission())
                    }
                    "requestStoragePermission" -> {
                        requestBasicReadPermission { granted ->
                            result.success(granted)
                        }
                    }

                    else -> result.notImplemented()
                }
            }

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
     * For content:// URIs, copies the file to the internal ROMs directory
     * so the native emulator core can read it directly.
     */
    private fun resolveUriToPath(uri: Uri): String? {
        if (uri.scheme == "file") return uri.path

        if (uri.scheme == "content") {
            try {
                val fileName = getFileName(uri) ?: "rom_${System.currentTimeMillis()}"
                val romsDir = File(filesDir, "roms")
                romsDir.mkdirs()
                val destFile = File(romsDir, fileName)

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

    // ══════════════════════════════════════════════════════════════
    //  SAF folder scanning + import
    // ══════════════════════════════════════════════════════════════

    /**
     * Recursively scan a SAF document tree for ROM files and copy them
     * to the app's internal ROM directory.
     */
    private fun importRomsFromTree(treeUri: Uri): List<String> {
        val romsDir = File(filesDir, "roms")
        if (!romsDir.exists()) romsDir.mkdirs()

        // Collect all ROM file URIs + names
        val romFiles = mutableListOf<Pair<Uri, String>>() // (fileUri, displayName)
        val docId = DocumentsContract.getTreeDocumentId(treeUri)
        scanTreeRecursive(treeUri, docId, romFiles)

        // Copy each ROM file to internal storage
        val importedPaths = mutableListOf<String>()
        for ((fileUri, name) in romFiles) {
            try {
                val destFile = File(romsDir, name)
                contentResolver.openInputStream(fileUri)?.use { input ->
                    destFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                importedPaths.add(destFile.absolutePath)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        return importedPaths
    }

    /**
     * Recursively enumerate children of a SAF document tree node,
     * collecting ROM files that match [ROM_EXTENSIONS].
     */
    private fun scanTreeRecursive(
        treeUri: Uri,
        parentDocId: String,
        results: MutableList<Pair<Uri, String>>
    ) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)

        try {
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null, null, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)

                while (cursor.moveToNext()) {
                    val docId = cursor.getString(idCol)
                    val name = cursor.getString(nameCol) ?: continue
                    val mime = cursor.getString(mimeCol)

                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        // Recurse into sub-directories
                        scanTreeRecursive(treeUri, docId, results)
                    } else {
                        // Check file extension
                        val ext = name.substringAfterLast('.', "").lowercase()
                        if (ext in ROM_EXTENSIONS) {
                            val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            results.add(Pair(fileUri, name))
                        }
                    }
                }
            }
        } catch (e: Exception) {
            // Some directories may not be accessible — skip them
            e.printStackTrace()
        }
    }

    // ══════════════════════════════════════════════════════════════
    //  Legacy basic storage permission (TV browser, Android ≤ 12)
    // ══════════════════════════════════════════════════════════════

    private fun hasBasicReadPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Android 13+: READ_EXTERNAL_STORAGE has no effect
            false
        } else {
            ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestBasicReadPermission(callback: (Boolean) -> Unit) {
        if (hasBasicReadPermission()) {
            callback(true)
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Android 13+: can't request READ_EXTERNAL_STORAGE
            callback(false)
            return
        }

        permissionResultHandler = callback
        ActivityCompat.requestPermissions(
            this,
            arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE),
            STORAGE_PERMISSION_CODE
        )
    }

    // ══════════════════════════════════════════════════════════════
    //  Activity result handling
    // ══════════════════════════════════════════════════════════════

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

        if (requestCode == SAF_IMPORT_FOLDER_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val treeUri = data.data!!

                // Persist read permission so folder can be re-scanned later
                try {
                    contentResolver.takePersistableUriPermission(
                        treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: Exception) {}

                // Scan + copy in background thread to avoid blocking UI
                Thread {
                    val importedPaths = importRomsFromTree(treeUri)
                    runOnUiThread {
                        importRomsResultHandler?.invoke(importedPaths)
                        importRomsResultHandler = null
                    }
                }.start()
            } else {
                importRomsResultHandler?.invoke(null)
                importRomsResultHandler = null
            }
        }
    }
}
