package org.localsend.localsend_app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.BaseColumns
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors


private const val CHANNEL = "org.localsend.localsend_app/localsend"
private const val REQUEST_CODE_PICK_DIRECTORY = 1
private const val REQUEST_CODE_PICK_DIRECTORY_PATH = 2
private const val REQUEST_CODE_PICK_FILE = 3
private const val REQUEST_CODE_LOCAL_NETWORK = 4

// Not available as a constant in compileSdk 36.
private const val PERMISSION_ACCESS_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
private const val API_LEVEL_ANDROID_17 = 37

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// share_handler drops share intents arriving via onNewIntent while the Dart side
    /// is not subscribed to its media stream yet, which happens when this singleTask
    /// activity is relaunched into an existing task while the app is still starting.
    /// Hold such intents back until Dart reports readiness ("shareIntentReady"), then
    /// replay them through the regular plugin path.
    private val pendingShareIntents = mutableListOf<Intent>()
    private var shareIntentReady = false

    /// Shuttle: action recorded when the "Send clipboard" tile opens the app; Dart fetches it once via takePendingAction
    private var pendingAction: String? = null

    /// Shuttle: used to tell Dart that a new action is pending (Dart gets no onResume while the app is already in front)
    private var methodChannel: MethodChannel? = null

    /// Only accepts "send clipboard" coming from our own quick settings tile. This activity is exported, so without
    /// a check any app could send the same action and make Shuttle send out the clipboard (which might hold a
    /// password you just copied). The intent must carry a token only this app knows ([tileToken], kept in private
    /// storage that other apps cannot read). Returns whether the action was accepted.
    private fun rememberAction(intent: Intent?): Boolean {
        if (intent?.action != ACTION_SEND_CLIPBOARD) return false
        val given = intent.getStringExtra(EXTRA_TILE_TOKEN) ?: return false
        val ok = java.security.MessageDigest.isEqual(given.toByteArray(), tileToken(this).toByteArray())
        if (ok) pendingAction = "send_clipboard"
        return ok
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // When the system recreates the activity after killing it, the original intent comes again: don't send twice
        if (savedInstanceState == null) rememberAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        // Since Android 10 a foreground activity is not paused and resumed around a new intent, so Dart never sees
        // onResume: notify it directly
        if (rememberAction(intent)) methodChannel?.invokeMethod("onPendingAction", null)
        if (!shareIntentReady && (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE)) {
            pendingShareIntents.add(intent)
            return
        }
        super.onNewIntent(intent)
    }

    private fun onShareIntentReady() {
        shareIntentReady = true
        val pending = pendingShareIntents.toList()
        pendingShareIntents.clear()
        for (intent in pending) {
            super.onNewIntent(intent)
        }
    }

    // Overriding the static methods we need from the Java class, as described
    // in the documentation of `FlutterActivity.NewEngineIntentBuilder`
    companion object {
        const val ACTION_SEND_CLIPBOARD = "com.jackw.shareme.SEND_CLIPBOARD"
        const val EXTRA_TILE_TOKEN = "com.jackw.shareme.TILE_TOKEN"
        private const val INTERNAL_PREFS = "shuttle_internal"

        /// Shared secret between the quick settings tile and this activity: generated randomly (128 bits) on first use
        /// and stored in this app's private preferences, which other apps cannot read.
        @Synchronized
        fun tileToken(context: Context): String {
            val prefs = context.getSharedPreferences(INTERNAL_PREFS, Context.MODE_PRIVATE)
            prefs.getString("tile_token", null)?.let { return it }
            val bytes = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
            val token = bytes.joinToString("") { "%02x".format(it) }
            prefs.edit().putString("tile_token", token).commit()
            return token
        }

        fun withNewEngine(): NewEngineIntentBuilder {
            return NewEngineIntentBuilder(MainActivity::class.java)
        }

        fun createDefaultIntent(launchContext: Context): Intent {
            return withNewEngine().build(launchContext)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).also { methodChannel = it }.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> {
                    pendingResult = result
                    openDirectoryPicker(onlyPath = false)
                }

                "pickFiles" -> {
                    pendingResult = result
                    openFilePicker()
                }

                "pickDirectoryPath" -> {
                    pendingResult = result
                    openDirectoryPicker(onlyPath = true)
                }

                "createDirectory" -> handleCreateDirectory(call, result)

                "getFileDescriptor" -> handleGetFileDescriptor(call, result)

                "createFile" -> handleCreateFile(call, result)

                "openFileForWriting" -> handleOpenFileForWriting(call, result)

                // Shuttle: on Android 10+ received images/videos are written straight into a MediaStore (gallery) entry
                // instead of a cache file that is copied over after the transfer
                "createMediaStoreFile" -> handleCreateMediaStoreFile(call, result)

                "finishMediaStoreFile" -> handleFinishMediaStoreFile(call, result)

                "deleteMediaStoreFile" -> handleDeleteMediaStoreFile(call, result)

                "deletePendingMediaStoreFiles" -> handleDeletePendingMediaStoreFiles(call, result)

                "scanFile" -> handleScanFile(call, result)

                "openContentUri" -> {
                    openUri(context, call.argument<String>("uri")!!)
                    result.success(null)
                }

                "openGallery" -> {
                    openGallery()
                    result.success(null)
                }

                // Shuttle: the "Background receiving" section of the settings page (Xiaomi)
                "isXiaomi" -> result.success(isXiaomi())
                "getFriendlyDeviceName" -> result.success(friendlyDeviceName())
                "takePendingAction" -> {
                    val action = pendingAction
                    pendingAction = null
                    result.success(action)
                }
                "openAutostartSettings" -> result.success(openAutostartSettings())
                "openBatterySaverSettings" -> result.success(openBatterySaverSettings())
                "requestIgnoreBatteryOptimizations" -> result.success(requestIgnoreBatteryOptimizations())

                "shareIntentReady" -> {
                    onShareIntentReady()
                    result.success(null)
                }

                "isAnimationsEnabled" -> {
                    result.success(isAnimationsEnabled())
                }

                "getDownloadsDirectory" -> {
                    result.success(getDownloadsDirectory())
                }

                "requestLocalNetworkPermission" -> {
                    if (hasLocalNetworkPermission()) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        requestPermissions(arrayOf(PERMISSION_ACCESS_LOCAL_NETWORK), REQUEST_CODE_LOCAL_NETWORK)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /// Android 17+ gates local network access behind a runtime permission; older versions grant it implicitly.
    private fun hasLocalNetworkPermission(): Boolean {
        if (Build.VERSION.SDK_INT < API_LEVEL_ANDROID_17) {
            return true
        }
        return checkSelfPermission(PERMISSION_ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_LOCAL_NETWORK) {
            pendingPermissionResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingPermissionResult = null
        }
    }

    /// Absolute path of the shared "Download" directory (usually /storage/emulated/0/Download).
    @Suppress("DEPRECATION")
    private fun getDownloadsDirectory(): String {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
    }

    private fun isAnimationsEnabled() : Boolean {
        return Settings.Global.getFloat(this.getContentResolver(),
            Settings.Global.ANIMATOR_DURATION_SCALE, 1.0f) != 0.0f;
    }

    private fun handleScanFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank() || !File(path).isAbsolute) {
            result.error("INVALID_ARGUMENT", "Expected an absolute filesystem path", null)
            return
        }

        try {
            MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null) { _, uri ->
                result.success(uri != null)
            }
        } catch (e: Exception) {
            result.error("SCAN_FAILED", e.message ?: "Failed to scan file", null)
        }
    }

    private fun handleGetFileDescriptor(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "r")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            // Ownership of the detached descriptor is transferred to the caller. It must be
            // closed by Rust (or whichever native consumer receives it) after use.
            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    /// Creates a new file inside a SAF directory and opens it for writing.
    ///
    /// Returns the URI of the created document (Android may rename the file on
    /// collisions) and an owned writable file descriptor. The descriptor must be
    /// closed by the native consumer it is passed to.
    private fun handleCreateFile(call: MethodCall, result: MethodChannel.Result) {
        val parentUriString = call.argument<String>("parentUri")
        val fileName = call.argument<String>("fileName")
        if (parentUriString == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Missing parentUri or fileName", null)
            return
        }

        try {
            val parentUri = Uri.parse(parentUriString)

            // A pure tree URI (content://…/tree/X) must be converted to its
            // document form before it can be used as a parent document.
            val segments = parentUri.pathSegments
            val parentDocumentUri = if (segments.size == 2 && segments[0] == "tree") {
                DocumentsContract.buildDocumentUriUsingTree(
                    parentUri,
                    DocumentsContract.getTreeDocumentId(parentUri)
                )
            } else {
                parentUri
            }

            // Providers append an extension when the MIME type does not match the one Android maps the
            // file's extension to (e.g. "test.conf" as text/plain becomes "test.conf.txt"), so derive it
            // from the same map. application/octet-stream keeps the name as-is for unknown extensions.
            val extension = fileName.substringAfterLast('.', "").lowercase(Locale.ROOT)
            val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                ?: "application/octet-stream"

            val documentUri =
                DocumentsContract.createDocument(contentResolver, parentDocumentUri, mimeType, fileName)
            if (documentUri == null) {
                result.error("CREATE_FAILED", "Could not create $fileName in $parentUriString", null)
                return
            }

            // "wt" is write + truncate: the document is new, unless the provider
            // handed out an existing one instead of creating a second document.
            val parcelFileDescriptor = contentResolver.openFileDescriptor(documentUri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(
                    mapOf(
                        "uri" to documentUri.toString(),
                        "fd" to it.detachFd(),
                    )
                )
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("CREATE_FAILED", e.message ?: "Failed to create file", null)
        }
    }

    /// Opens an existing document created by [handleCreateFile] for writing,
    /// discarding its current content.
    ///
    /// Used to write a file again after a failed attempt, so that it keeps its
    /// name instead of being created a second time under a numbered one.
    ///
    /// Returns an owned writable file descriptor. It stays open after this call
    /// and must be closed by the native consumer it is passed to.
    private fun handleOpenFileForWriting(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            // "wt" is write + truncate. A document provider may ignore the
            // truncation, so the writer additionally shortens the file itself.
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    // ───────── Gallery entries written in place (Android 10+) ─────────
    //
    // A received image or video is written straight into a MediaStore entry instead of a cache file that is
    // copied into the gallery afterwards. The entry is created pending (IS_PENDING = 1): other apps, the
    // gallery included, do not see it until it is published, so a half-received file never shows up.
    // Images go to Pictures/ and videos to Movies/, where the gallery saves went before (gal plugin).

    /// MediaStore calls touch its database and, when publishing, scan the file, so they run off the main thread,
    /// one after another (which also keeps two entries from picking the same free name at the same time).
    private val mediaStoreExecutor by lazy { Executors.newSingleThreadExecutor() }
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    private class MediaStoreError(val code: String, message: String) : Exception(message)

    private fun runMediaStoreCall(result: MethodChannel.Result, block: () -> Any?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("UNSUPPORTED_SDK", "Writing gallery entries in place needs Android 10", null)
            return
        }
        mediaStoreExecutor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: MediaStoreError) {
                mainHandler.post { result.error(e.code, e.message, null) }
            } catch (e: SecurityException) {
                mainHandler.post { result.error("PERMISSION_DENIED", e.message ?: "Permission denied", null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("MEDIA_STORE_FAILED", e.message ?: e.toString(), null) }
            }
        }
    }

    private fun mediaCollection(isImage: Boolean): Uri =
        if (isImage) MediaStore.Images.Media.EXTERNAL_CONTENT_URI else MediaStore.Video.Media.EXTERNAL_CONTENT_URI

    /// As stored by MediaStore, with the trailing slash.
    private fun galleryRelativePath(isImage: Boolean): String =
        (if (isImage) Environment.DIRECTORY_PICTURES else Environment.DIRECTORY_MOVIES) + "/"

    /// Only URIs of the MediaStore entries above are accepted.
    private fun mediaStoreUri(call: MethodCall): Uri {
        val uri = call.argument<String>("uri")?.let(Uri::parse)
        if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT || uri.authority != MediaStore.AUTHORITY) {
            throw MediaStoreError("INVALID_ARGUMENT", "Expected a MediaStore content URI")
        }
        return uri
    }

    /// Creates a pending entry for [fileName] and opens it for writing.
    ///
    /// Returns the URI of the entry (its name may get a number when it is taken) and an owned writable file
    /// descriptor, which must be closed by the native consumer it is passed to. Fails with UNSUPPORTED_FORMAT
    /// when the extension is not one of an image (or video), which the gallery would reject.
    private fun handleCreateMediaStoreFile(call: MethodCall, result: MethodChannel.Result) {
        val fileName = call.argument<String>("fileName")
        val isImage = call.argument<Boolean>("isImage")
        if (fileName.isNullOrEmpty() || isImage == null) {
            result.error("INVALID_ARGUMENT", "Missing fileName or isImage", null)
            return
        }
        runMediaStoreCall(result) {
            @SuppressLint("NewApi") // checked by runMediaStoreCall
            val created = createMediaStoreFile(fileName, isImage)
            created
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun createMediaStoreFile(fileName: String, isImage: Boolean): Map<String, Any> {
        val dot = fileName.lastIndexOf('.')
        val extension = if (dot >= 0) fileName.substring(dot + 1).lowercase(Locale.ROOT) else ""
        val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
        if (extension.isEmpty() || mimeType == null || !mimeType.startsWith(if (isImage) "image/" else "video/")) {
            throw MediaStoreError("UNSUPPORTED_FORMAT", "$fileName is not saved as ${if (isImage) "an image" else "a video"}")
        }

        val collection = mediaCollection(isImage)
        val relativePath = galleryRelativePath(isImage)
        val base = fileName.substring(0, dot)
        val suffix = fileName.substring(dot)
        for (counter in 1..1000) {
            val name = if (counter == 1) fileName else "$base ($counter)$suffix"
            if (mediaStoreNameTaken(collection, relativePath, name)) continue

            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = try {
                contentResolver.insert(collection, values)
                    ?: throw MediaStoreError("CREATE_FAILED", "MediaStore created no entry for $name")
            } catch (e: IllegalStateException) {
                // MediaStore numbers a taken name itself, but gives up after a few dozen; carry on with ours.
                if (e.message?.contains("Failed to build unique file") == true) continue
                throw e
            }

            try {
                val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "w")
                    ?: throw MediaStoreError("OPEN_FAILED", "MediaStore returned no file descriptor for $uri")
                parcelFileDescriptor.use {
                    return mapOf("uri" to uri.toString(), "fd" to it.detachFd())
                }
            } catch (e: Exception) {
                deleteMediaStoreEntry(uri)
                throw e
            }
        }
        throw MediaStoreError("CREATE_FAILED", "No free name for $fileName")
    }

    /// Whether an entry of this app, published or still pending, already uses [name] in [relativePath].
    /// Two files with the same name can be received at the same time, and while both are pending MediaStore
    /// does not necessarily count the other one as taken.
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun mediaStoreNameTaken(collection: Uri, relativePath: String, name: String): Boolean {
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.DISPLAY_NAME} = ?"
        val selectionArgs = arrayOf(relativePath, name)
        val projection = arrayOf(BaseColumns._ID)
        val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val queryArgs = Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs)
                putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
            }
            contentResolver.query(collection, projection, queryArgs, null)
        } else {
            @Suppress("DEPRECATION")
            contentResolver.query(MediaStore.setIncludePending(collection), projection, selection, selectionArgs, null)
        }
        return cursor?.use { it.count > 0 } ?: false
    }

    /// Deletes an entry of this app, pending or not. Returns whether it was there.
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun deleteMediaStoreEntry(uri: Uri): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            contentResolver.delete(uri, Bundle().apply { putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE) }) > 0
        } else {
            @Suppress("DEPRECATION")
            contentResolver.delete(MediaStore.setIncludePending(uri), null, null) > 0
        }
    }

    /// Publishes a completely written entry: it shows up in the gallery and gets scanned.
    private fun handleFinishMediaStoreFile(call: MethodCall, result: MethodChannel.Result) {
        runMediaStoreCall(result) {
            val uri = mediaStoreUri(call)
            val values = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            @SuppressLint("NewApi") // checked by runMediaStoreCall
            val updated = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                contentResolver.update(uri, values, Bundle().apply { putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE) })
            } else {
                @Suppress("DEPRECATION")
                contentResolver.update(MediaStore.setIncludePending(uri), values, null, null)
            }
            if (updated != 1) throw MediaStoreError("PUBLISH_FAILED", "Could not publish $uri")
            null
        }
    }

    /// Deletes the entry of a failed or canceled transfer.
    private fun handleDeleteMediaStoreFile(call: MethodCall, result: MethodChannel.Result) {
        runMediaStoreCall(result) {
            val uri = mediaStoreUri(call)
            @SuppressLint("NewApi") // checked by runMediaStoreCall
            val deleted = deleteMediaStoreEntry(uri)
            deleted
        }
    }

    /// Deletes the entries this app left pending before [createdBefore] (seconds since the epoch), e.g. when it
    /// was closed in the middle of a transfer. Only never-published entries of this app in Pictures/ and Movies/,
    /// so only half-received files. Returns how many were deleted.
    private fun handleDeletePendingMediaStoreFiles(call: MethodCall, result: MethodChannel.Result) {
        val createdBefore = call.argument<Number>("createdBefore")?.toLong()
        if (createdBefore == null) {
            result.error("INVALID_ARGUMENT", "Missing createdBefore", null)
            return
        }
        runMediaStoreCall(result) {
            @SuppressLint("NewApi") // checked by runMediaStoreCall
            val deleted = deletePendingMediaStoreFiles(createdBefore)
            deleted
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun deletePendingMediaStoreFiles(createdBefore: Long): Int {
        var deleted = 0
        for (isImage in listOf(true, false)) {
            val collection = mediaCollection(isImage)
            val selection = "${MediaStore.MediaColumns.IS_PENDING} = 1 AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND " +
                "${MediaStore.MediaColumns.OWNER_PACKAGE_NAME} = ? AND ${MediaStore.MediaColumns.DATE_ADDED} < ?"
            val selectionArgs = arrayOf(galleryRelativePath(isImage), packageName, createdBefore.toString())
            val projection = arrayOf(BaseColumns._ID)
            val cursor = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val queryArgs = Bundle().apply {
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                    putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs)
                    putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_ONLY)
                }
                contentResolver.query(collection, projection, queryArgs, null)
            } else {
                @Suppress("DEPRECATION")
                contentResolver.query(MediaStore.setIncludePending(collection), projection, selection, selectionArgs, null)
            }
            val ids = cursor?.use { c -> buildList { while (c.moveToNext()) add(c.getLong(0)) } } ?: emptyList()
            for (id in ids) {
                if (deleteMediaStoreEntry(ContentUris.withAppendedId(collection, id))) deleted++
            }
        }
        return deleted
    }

    private fun openDirectoryPicker(onlyPath: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        startActivityForResult(
            intent,
            if (onlyPath) REQUEST_CODE_PICK_DIRECTORY_PATH else REQUEST_CODE_PICK_DIRECTORY
        )
    }

    private fun openFilePicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra("multi-pick", true)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_CODE_PICK_FILE)
    }

    @SuppressLint("WrongConstant")
    @Override
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == Activity.RESULT_CANCELED) {
            pendingResult?.error("CANCELED", "Canceled", null)
            pendingResult = null
            return
        }

        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult?.error("Error $resultCode", "Failed to access directory or file", null)
            pendingResult = null
            return
        }

        when (requestCode) {
            REQUEST_CODE_PICK_DIRECTORY -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)

                    val files = mutableListOf<FileInfo>()
                    listFiles(uri, files)
                    val resultData = PickDirectoryResult(uri.toString(), files)
                    pendingResult?.success(resultData.toMap())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_DIRECTORY_PATH -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    pendingResult?.success(uri.toString())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_FILE -> {
                val uriList: List<Uri> = when {
                    data.clipData != null -> {
                        val clipData = data.clipData
                        val uris = mutableListOf<Uri>()
                        for (i in 0 until clipData!!.itemCount) {
                            uris.add(clipData.getItemAt(i).uri)
                        }
                        uris
                    }

                    data.data != null -> listOf(data.data!!)
                    else -> {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                }

                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

                val resultList = mutableListOf<FileInfo>()
                for (uri in uriList) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    val documentFile = FastDocumentFile.fromDocumentUri(this, uri)
                    if (documentFile == null) {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                    resultList.add(
                        FileInfo(
                            name = documentFile.name,
                            size = documentFile.size,
                            uri = uri.toString(),
                            lastModified = documentFile.lastModified?.toRfc3339(),
                        )
                    )
                }

                pendingResult?.success(resultList.map { it.toMap() })
                pendingResult = null
            }
        }
    }

    private fun listFiles(uri: Uri, files: MutableList<FileInfo>) {
        val pickedDir: FastDocumentFile = FastDocumentFile.fromTreeUri(this, uri)

        for (file in pickedDir.listFiles()) {
            if (file.isDirectory) {
                // Recursive call
                listFiles(file.uri, files)
            } else if (file.isFile) {
                files.add(
                    FileInfo(
                        name = file.name,
                        size = file.size,
                        uri = file.uri.toString(),
                        lastModified = file.lastModified?.toRfc3339(),
                    ),
                )
            }
        }
    }

    @SuppressLint("WrongConstant")
    private fun handleCreateDirectory(call: MethodCall, result: MethodChannel.Result) {
        val documentUri = Uri.parse(call.argument<String>("documentUri")!!)
        val directoryName = call.argument<String>("directoryName")!!

        if (folderExists(documentUri, directoryName)) {
            result.success(null)
            return
        }

        DocumentsContract.createDocument(
            context.contentResolver, documentUri, DocumentsContract.Document.MIME_TYPE_DIR,
            directoryName
        )

        result.success(null)
    }

    private fun folderExists(documentUri: Uri, folderName: String): Boolean {
        var cursor: Cursor? = null
        try {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(documentUri, DocumentsContract.getDocumentId(documentUri))
            cursor = contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null,
                null,
                null,
            )

            if (cursor != null) {
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(0)
                    val mimeType = cursor.getString(1)

                    if (folderName == displayName && DocumentsContract.Document.MIME_TYPE_DIR == mimeType) {
                        return true
                    }
                }
            }
        } finally {
            cursor?.close()
        }
        return false
    }

    private fun openGallery() {
        val intent = Intent()
        intent.action = Intent.ACTION_VIEW
        intent.type = "image/*"
        startActivity(intent)
    }

    // ───────── Shuttle: shortcuts to Xiaomi's background settings ─────────
    // Xiaomi does not document these screens. The component names come from community findings (Stack Overflow /
    // GitHub Gists) and may differ between MIUI versions, so each helper tries the Xiaomi screen first and falls
    // back to the system "App info" screen. Each returns which screen it actually opened.

    // ───────── Shuttle: a recognizable device name ─────────
    // Xiaomi sets the system device_name to a model code; the name the user picked is stored in
    // persist.sys.device_name and in the Bluetooth name, and the marketing name in ro.product.marketname.
    // Order: user-picked name → system device name (when it is not the model code) → marketing name → model code,
    // skipping whatever cannot be read. The system may block any of these reads, so each one is wrapped in a try.
    private fun friendlyDeviceName(): String {
        val model = Build.MODEL ?: ""
        fun usable(name: String?): String? = name?.trim()?.takeIf { it.isNotEmpty() && it != model && it != "null" }
        return usable(systemProperty("persist.sys.device_name"))
            ?: usable(readSetting { Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) })
            ?: usable(readSetting { Settings.Secure.getString(contentResolver, "bluetooth_name") })
            ?: usable(systemProperty("ro.product.marketname"))
            ?: model
    }

    private fun readSetting(read: () -> String?): String? = try {
        read()
    } catch (e: Exception) {
        null
    }

    @SuppressLint("PrivateApi")
    private fun systemProperty(key: String): String? = try {
        Class.forName("android.os.SystemProperties").getMethod("get", String::class.java).invoke(null, key) as? String
    } catch (e: Exception) {
        null
    }

    private fun isXiaomi(): Boolean {
        val brand = Build.MANUFACTURER.lowercase(Locale.ROOT)
        return brand == "xiaomi" || brand == "redmi" || brand == "poco"
    }

    private fun tryStart(intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun openAppDetails(): String {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
        return if (tryStart(intent)) "appDetails" else "none"
    }

    /// Xiaomi "Autostart" management screen
    private fun openAutostartSettings(): String {
        val intent = Intent().setComponent(
            android.content.ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")
        )
        return if (isXiaomi() && tryStart(intent)) "miui" else openAppDetails()
    }

    /// Requests exemption from battery optimization (Android's power-saving allowlist).
    /// Xiaomi registers its own battery saver screen as a handler for this request too, so sending it as is pops up a
    /// confusing app chooser. So first target the standard dialog of the system Settings app (Allow / Deny), and fall
    /// back to an ordinary intent if that fails.
    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations(): String {
        val uri = Uri.parse("package:$packageName")
        val standard = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, uri).setPackage("com.android.settings")
        if (tryStart(standard)) return "android"
        val any = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, uri)
        return if (tryStart(any)) "other" else openAppDetails()
    }

    /// Xiaomi "Battery saver" settings for this app (where it can be set to "No restrictions")
    private fun openBatterySaverSettings(): String {
        val intent = Intent().setComponent(
            android.content.ComponentName("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")
        )
        intent.putExtra("package_name", packageName)
        intent.putExtra("package_label", applicationInfo.loadLabel(packageManager).toString())
        return if (isXiaomi() && tryStart(intent)) "miui" else openAppDetails()
    }
}

data class PickDirectoryResult(
    val directoryUri: String,
    val files: List<FileInfo>,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "directoryUri" to directoryUri,
            "files" to files.map { it.toMap() }
        )
    }
}

data class FileInfo(
    val name: String,
    val size: Long,
    val uri: String,
    val lastModified: String?
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "name" to name,
            "size" to size,
            "uri" to uri,
            "lastModified" to lastModified
        )
    }
}

/// Formats milliseconds since epoch as an RFC 3339 string in UTC.
private fun Long.toRfc3339(): String {
    val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    format.timeZone = TimeZone.getTimeZone("UTC")
    return format.format(Date(this))
}
