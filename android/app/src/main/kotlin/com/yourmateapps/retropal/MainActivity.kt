package com.yourmateapps.retropal

import android.app.ActivityManager
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
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

    // Texture bridge for zero-copy frame delivery
    private var textureBridge: YageTextureBridge? = null

    // Callback for picking folder (setup) — returns URI only
    private var pickFolderResultHandler: ((String?) -> Unit)? = null

    companion object {
        private const val SAF_IMPORT_FOLDER_CODE = 2001
        private const val SAF_PICK_FOLDER_CODE = 2002
        private const val STORAGE_PERMISSION_CODE = 1001
        private val ROM_EXTENSIONS = setOf("gba", "gb", "gbc", "sgb", "nes", "sfc", "smc")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize texture bridge for zero-copy frame delivery
        textureBridge = YageTextureBridge(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> {
                        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
                        val isTV = uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                        result.success(isTV)
                    }
                    "getDeviceMemoryMB" -> {
                        val memInfo = ActivityManager.MemoryInfo()
                        (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memInfo)
                        result.success((memInfo.totalMem / (1024 * 1024)).toInt())
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

                    // ── Pick folder for setup (returns URI only, no import) ──
                    "pickRomsFolder" -> {
                        pickFolderResultHandler = { uri ->
                            result.success(uri)
                        }
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                        startActivityForResult(intent, SAF_PICK_FOLDER_CODE)
                    }

                    // ── Import from persisted folder URI (no picker) ──
                    "importFromFolderUri" -> {
                        val treeUri = call.argument<String>("treeUri")
                        if (treeUri == null) {
                            result.success(emptyList<String>())
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val uri = Uri.parse(treeUri)
                                val importedPaths = importRomsFromTree(uri)
                                runOnUiThread { result.success(importedPaths) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(emptyList<String>()) }
                            }
                        }.start()
                    }

                    // ── Copy a save file from internal storage to user folder (SAF tree) ──
                    "copySaveToUserFolder" -> {
                        val treeUri = call.argument<String>("treeUri")
                        val sourcePath = call.argument<String>("sourcePath")
                        if (treeUri == null || sourcePath == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        Thread {
                            try {
                                val success = copyFileToTree(Uri.parse(treeUri), sourcePath)
                                runOnUiThread { result.success(success) }
                            } catch (e: Exception) {
                                e.printStackTrace()
                                runOnUiThread { result.success(false) }
                            }
                        }.start()
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

                    // ── Texture rendering — zero-copy frame delivery ──
                    "createGameTexture" -> {
                        val width = call.argument<Int>("width") ?: 240
                        val height = call.argument<Int>("height") ?: 160
                        val textureId = textureBridge?.createTexture(width, height)
                        result.success(textureId)
                    }
                    "destroyGameTexture" -> {
                        textureBridge?.destroy()
                        result.success(null)
                    }
                    "updateGameTextureSize" -> {
                        val width = call.argument<Int>("width") ?: 240
                        val height = call.argument<Int>("height") ?: 160
                        textureBridge?.updateSize(width, height)
                        result.success(null)
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

    override fun onDestroy() {
        textureBridge?.destroy()
        textureBridge = null
        super.onDestroy()
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
     * ROM file with parent doc ID (for finding sibling save files).
     */
    private data class RomEntry(val fileUri: Uri, val name: String, val parentDocId: String)

    /**
     * Recursively scan a SAF document tree for ROM files and copy them
     * to the app's internal ROM directory. Also copies matching save files
     * (.sav, .ss0-.ss5, .ss0.png-.ss5.png, baseName_*.png) from the same folder.
     */
    private fun importRomsFromTree(treeUri: Uri): List<String> {
        val romsDir = File(filesDir, "roms")
        if (!romsDir.exists()) romsDir.mkdirs()

        val romFiles = mutableListOf<RomEntry>()
        val docId = DocumentsContract.getTreeDocumentId(treeUri)
        scanTreeRecursive(treeUri, docId, null, romFiles)

        val importedPaths = mutableListOf<String>()
        for (entry in romFiles) {
            try {
                val destFile = File(romsDir, entry.name)
                contentResolver.openInputStream(entry.fileUri)?.use { input ->
                    destFile.outputStream().use { output ->
                        input.copyTo(output)
                    }
                }
                importedPaths.add(destFile.absolutePath)
                copyMatchingSaves(treeUri, entry.parentDocId, entry.name, romsDir)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }

        return importedPaths
    }

    /**
     * Copy a file from internal storage to the user's SAF document tree.
     * Used to sync battery saves and save states to the user folder.
     */
    private fun copyFileToTree(treeUri: Uri, sourcePath: String): Boolean {
        val sourceFile = File(sourcePath)
        if (!sourceFile.exists()) return false
        val fileName = sourceFile.name
        val docId = DocumentsContract.getTreeDocumentId(treeUri)
        val mimeType = getMimeType(fileName)
        return try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
            val childUri = DocumentsContract.createDocument(contentResolver, docUri, mimeType, fileName)
                ?: return false
            contentResolver.openOutputStream(childUri)?.use { output ->
                sourceFile.inputStream().use { input ->
                    input.copyTo(output)
                }
            }
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    private fun getMimeType(fileName: String): String {
        val ext = fileName.substringAfterLast('.', "")
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    /**
     * Copy save files that match the ROM from the same directory.
     * Patterns: baseName.sav, romBase.ss0-5, romBase.ss0-5.png, baseName_*.png
     */
    private fun copyMatchingSaves(treeUri: Uri, parentDocId: String, romName: String, romsDir: File) {
        val baseName = romName.substringBeforeLast('.', romName)
        val savePrefixes = listOf(
            "$baseName.sav",
            "$romName.ss0", "$romName.ss1", "$romName.ss2",
            "$romName.ss3", "$romName.ss4", "$romName.ss5",
            "$romName.ss0.png", "$romName.ss1.png", "$romName.ss2.png",
            "$romName.ss3.png", "$romName.ss4.png", "$romName.ss5.png"
        ).toSet()
        val screenshotPrefix = "${baseName}_"
        val screenshotSuffix = ".png"

        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        try {
            contentResolver.query(
                childUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null, null, null
            )?.use { cursor ->
                val idCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameCol = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)

                while (cursor.moveToNext()) {
                    val docId = cursor.getString(idCol)
                    val name = cursor.getString(nameCol) ?: continue
                    val mime = cursor.getString(cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE))

                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue

                    val shouldCopy = name in savePrefixes ||
                        (name.startsWith(screenshotPrefix) && name.endsWith(screenshotSuffix))

                    if (shouldCopy) {
                        try {
                            val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            val destFile = File(romsDir, name)
                            contentResolver.openInputStream(fileUri)?.use { input ->
                                destFile.outputStream().use { output ->
                                    input.copyTo(output)
                                }
                            }
                        } catch (_: Exception) {}
                    }
                }
            }
        } catch (_: Exception) {}
    }

    /**
     * Recursively enumerate children of a SAF document tree node,
     * collecting ROM files that match [ROM_EXTENSIONS].
     * [parentDocIdForSaves] is the doc ID of the directory containing these files (for save-file lookup).
     */
    private fun scanTreeRecursive(
        treeUri: Uri,
        parentDocId: String,
        parentDocIdForSaves: String?,
        results: MutableList<RomEntry>
    ) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocId)
        val currentDirAsParent = parentDocIdForSaves ?: parentDocId

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

                    val isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR
                    val mightBeDirectory = mime.isNullOrEmpty()

                    if (isDirectory) {
                        scanTreeRecursive(treeUri, docId, docId, results)
                    } else if (mightBeDirectory) {
                        val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
                        try {
                            contentResolver.query(childUri, null, null, null, null)?.use { childCursor ->
                                if (childCursor.moveToFirst()) {
                                    scanTreeRecursive(treeUri, docId, docId, results)
                                } else {
                                    val ext = name.substringAfterLast('.', "").lowercase()
                                    if (ext in ROM_EXTENSIONS) {
                                        val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                        results.add(RomEntry(fileUri, name, currentDirAsParent))
                                    }
                                }
                            } ?: run {
                                val ext = name.substringAfterLast('.', "").lowercase()
                                if (ext in ROM_EXTENSIONS) {
                                    val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                    results.add(RomEntry(fileUri, name, currentDirAsParent))
                                }
                            }
                        } catch (_: Exception) {
                            val ext = name.substringAfterLast('.', "").lowercase()
                            if (ext in ROM_EXTENSIONS) {
                                val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                results.add(RomEntry(fileUri, name, currentDirAsParent))
                            }
                        }
                    } else {
                        val ext = name.substringAfterLast('.', "").lowercase()
                        if (ext in ROM_EXTENSIONS) {
                            val fileUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                            results.add(RomEntry(fileUri, name, currentDirAsParent))
                        }
                    }
                }
            }
        } catch (e: Exception) {
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
                        treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
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

        if (requestCode == SAF_PICK_FOLDER_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val treeUri = data.data!!

                // Persist read+write so we can sync saves to this folder
                try {
                    contentResolver.takePersistableUriPermission(
                        treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Exception) {}

                pickFolderResultHandler?.invoke(treeUri.toString())
            } else {
                pickFolderResultHandler?.invoke(null)
            }
            pickFolderResultHandler = null
        }
    }
}
