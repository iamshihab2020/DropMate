package com.dropmate.dropmate

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.media.MediaMetadataRetriever
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.ext.SdkExtensions
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/** Method channel "dropmate/platform" — see lib/platform/native.dart. */
@SuppressLint("StaticFieldLeak")
object Bridge {
    private const val PICK_FILES = 7101
    private const val PICK_FOLDER = 7102
    private const val PERM = 7103
    private const val PICK_MEDIA = 7104

    private lateinit var app: Context
    private lateinit var channel: MethodChannel
    var activity: Activity? = null
    private val io = Executors.newFixedThreadPool(3)
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingPerm: MethodChannel.Result? = null
    private val handles = HashMap<Int, Pair<ParcelFileDescriptor, FileInputStream>>()
    private var nextHandle = 1
    private var sharesReady = false
    private val queuedShares = ArrayList<List<Map<String, Any?>>>()
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private var multicast: WifiManager.MulticastLock? = null

    fun attach(context: Context, engine: FlutterEngine) {
        app = context.applicationContext
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dropmate/platform")
        channel.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Exception) {
                result.error("native", e.message, null)
            }
        }
    }

    private fun bg(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            try {
                val v = work()
                main.post { result.success(v) }
            } catch (e: Exception) {
                main.post { result.error("io", e.message, null) }
            }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "freeBytes" -> result.success(StatFs(call.argument<String>("path")!!).availableBytes)
            "scanFile" -> {
                MediaScannerConnection.scanFile(app, arrayOf(call.argument<String>("path")), null, null)
                result.success(null)
            }
            "transferActive" -> { transferLocks(call.argument<Boolean>("on") == true); result.success(null) }
            "multicastLock" -> { multicastLock(call.argument<Boolean>("on") == true); result.success(null) }
            "startService" -> { ListenService.start(app); result.success(null) }
            "ignoringBattery" -> result.success(
                (app.getSystemService(Context.POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(app.packageName))
            "requestIgnoreBattery" -> {
                @SuppressLint("BatteryLife")
                val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${app.packageName}"))
                (activity ?: return result.success(null)).startActivity(i)
                result.success(null)
            }
            "manufacturer" -> result.success(Build.MANUFACTURER)
            "model" -> result.success(Build.MODEL)
            "needsStorage" -> result.success(
                Build.VERSION.SDK_INT <= 29 && !granted(Manifest.permission.WRITE_EXTERNAL_STORAGE))
            "requestStorage" -> requestPerm(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), result)
            "requestCamera" -> requestPerm(arrayOf(Manifest.permission.CAMERA), result)
            "vpnActive" -> {
                val cm = app.getSystemService(ConnectivityManager::class.java)
                val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                result.success(caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true)
            }
            "openFile" -> { view(call.argument<String>("path")!!, Intent.ACTION_VIEW); result.success(null) }
            "shareFile" -> { view(call.argument<String>("path")!!, Intent.ACTION_SEND); result.success(null) }
            "pickFiles" -> {
                val a = activity ?: return result.success(emptyList<Any>())
                pending = result
                val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                }
                a.startActivityForResult(i, PICK_FILES)
            }
            "pickMedia" -> {
                val a = activity ?: return result.success(emptyList<Any>())
                pending = result
                a.startActivityForResult(mediaPicker(), PICK_MEDIA)
            }
            "thumb" -> bg(result) { thumb(call.argument<String>("ref")!!, call.argument<Int>("size")!!) }
            "buzz" -> { Buzz.start(app, call.argument<String>("from")!!); result.success(null) }
            "stopBuzz" -> { Buzz.stop(app, tellDart = false); result.success(null) }
            "pickFolder" -> {
                val a = activity ?: return result.success(emptyList<Any>())
                pending = result
                a.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PICK_FOLDER)
            }
            "pickDirectory" -> result.success(null) // shortcut: Android saves under Download/; SAF trees can't be written with File APIs
            "stat" -> bg(result) { stat(Uri.parse(call.argument<String>("uri")), null) }
            "open" -> bg(result) {
                val pfd = app.contentResolver.openFileDescriptor(Uri.parse(call.argument<String>("uri")), "r")!!
                synchronized(handles) {
                    val h = nextHandle++
                    handles[h] = pfd to FileInputStream(pfd.fileDescriptor)
                    h
                }
            }
            "read" -> bg(result) {
                val (_, s) = synchronized(handles) { handles[call.argument<Int>("h")!!] }!!
                val len = call.argument<Int>("length")!!
                val buf = ByteBuffer.allocate(len)
                val ch = s.channel
                synchronized(s) {
                    ch.position((call.argument<Any>("offset") as Number).toLong())
                    while (buf.hasRemaining()) if (ch.read(buf) < 0) break
                }
                if (buf.position() == len) buf.array() else buf.array().copyOf(buf.position())
            }
            "close" -> {
                synchronized(handles) { handles.remove(call.argument<Int>("h")) }?.let { (p, s) -> s.close(); p.close() }
                result.success(null)
            }
            "readyForShares" -> {
                sharesReady = true
                queuedShares.forEach { channel.invokeMethod("shared", it) }
                queuedShares.clear()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun granted(p: String) = ContextCompat.checkSelfPermission(app, p) == PackageManager.PERMISSION_GRANTED

    private fun requestPerm(perms: Array<String>, result: MethodChannel.Result) {
        if (perms.all { granted(it) }) return result.success(true)
        val a = activity ?: return result.success(false)
        pendingPerm = result
        ActivityCompat.requestPermissions(a, perms, PERM)
    }

    fun onPermissionResult(code: Int, grants: IntArray) {
        if (code != PERM) return
        pendingPerm?.success(grants.isNotEmpty() && grants.all { it == PackageManager.PERMISSION_GRANTED })
        pendingPerm = null
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?) {
        val r = pending ?: return
        if (code != PICK_FILES && code != PICK_FOLDER && code != PICK_MEDIA) return
        pending = null
        if (resultCode != Activity.RESULT_OK || data == null) return r.success(emptyList<Any>())
        if (code != PICK_FOLDER) {
            val uris = ArrayList<Uri>()
            data.clipData?.let { c -> for (i in 0 until c.itemCount) uris.add(c.getItemAt(i).uri) }
            data.data?.let { if (uris.isEmpty()) uris.add(it) }
            bg(r) { uris.mapNotNull { u -> keepPermission(u); stat(u, null) } }
        } else {
            val tree = data.data!!
            keepPermission(tree)
            bg(r) { walkTree(tree) }
        }
    }

    private fun keepPermission(u: Uri) {
        try {
            app.contentResolver.takePersistableUriPermission(u, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) {
        }
    }

    fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val uris = ArrayList<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> intent.getParcelableExtraCompat(Intent.EXTRA_STREAM)?.let { uris.add(it) }
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtraCompat(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
            else -> return
        }
        // Only other apps' content; never a file:// path or our own provider, or a caller could
        // borrow DropMate's permissions to read its private files (confused deputy).
        uris.retainAll { it.scheme == "content" && it.authority?.startsWith(app.packageName) != true }
        if (uris.isEmpty()) return
        io.execute {
            val items = uris.mapNotNull { stat(it, null) }
            main.post {
                if (sharesReady) channel.invokeMethod("shared", items) else queuedShares.add(items)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun Intent.getParcelableExtraCompat(k: String): Uri? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(k, Uri::class.java) else getParcelableExtra(k)

    @Suppress("DEPRECATION")
    private fun Intent.getParcelableArrayListExtraCompat(k: String): ArrayList<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableArrayListExtra(k, Uri::class.java) else getParcelableArrayListExtra(k)

    private fun stat(u: Uri, rel: String?): Map<String, Any?>? {
        var name: String? = null
        var size = -1L
        app.contentResolver.query(u, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val s = c.getColumnIndex(OpenableColumns.SIZE)
                if (n >= 0) name = c.getString(n)
                if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
            }
        }
        if (size < 0) {
            // Some providers don't report size; ask the descriptor.
            size = app.contentResolver.openFileDescriptor(u, "r")?.use { it.statSize } ?: return null
        }
        var mtime = 0L
        try {
            app.contentResolver.query(u, arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) mtime = c.getLong(0)
            }
        } catch (_: Exception) {
        }
        return mapOf(
            "uri" to u.toString(),
            "rel" to (rel ?: name ?: "file"),
            "size" to size,
            "mime" to app.contentResolver.getType(u),
            "mtime" to mtime,
        )
    }

    private fun walkTree(tree: Uri): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val rootName = app.contentResolver.query(
            DocumentsContract.buildDocumentUriUsingTree(tree, rootId),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null
        )?.use { if (it.moveToFirst()) it.getString(0) else null } ?: "Folder"
        fun walk(docId: String, prefix: String) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId)
            app.contentResolver.query(
                children, arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                ), null, null, null
            )?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0)
                    val name = c.getString(1)
                    val mime = c.getString(2)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        walk(id, "$prefix/$name")
                    } else {
                        out.add(mapOf(
                            "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                            "rel" to "$prefix/$name",
                            "size" to c.getLong(3),
                            "mime" to mime,
                            "mtime" to (if (c.isNull(4)) 0L else c.getLong(4)),
                        ))
                    }
                }
            }
        }
        walk(rootId, rootName)
        return out
    }

    fun buzzStopped() = main.post { channel.invokeMethod("buzzStopped", null) }

    /** Android's photo picker (gallery grid) where available, else the system picker limited to photos and videos. */
    @SuppressLint("NewApi")
    private fun mediaPicker(): Intent {
        val photoPicker = Build.VERSION.SDK_INT >= 33 ||
            (Build.VERSION.SDK_INT >= 30 && SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2)
        return if (photoPicker) Intent(MediaStore.ACTION_PICK_IMAGES).apply {
            putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit())
        } else Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
    }

    private fun refUri(ref: String): Uri =
        if (ref.startsWith("content:")) Uri.parse(ref) else Uri.fromFile(File(ref.removePrefix("file:")))

    /** A JPEG at most [px] on its long side, upright, of a photo or a video frame; null if unreadable. */
    private fun thumb(ref: String, px: Int): ByteArray? {
        val uri = refUri(ref)
        val mime = if (uri.scheme == "content") app.contentResolver.getType(uri)
        else MimeTypeMap.getSingleton().getMimeTypeFromExtension(File(uri.path ?: "").extension.lowercase())
        var bmp: Bitmap? = null
        if (Build.VERSION.SDK_INT >= 29 && uri.scheme == "content") {
            bmp = try { app.contentResolver.loadThumbnail(uri, android.util.Size(px, px), null) } catch (_: Exception) { null }
        }
        if (bmp == null) bmp = if (mime?.startsWith("video/") == true) videoFrame(uri, px) else imageSampled(uri, px)
        if (bmp == null) return null
        val scale = px.toFloat() / maxOf(bmp.width, bmp.height)
        if (scale < 1) bmp = Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt(), (bmp.height * scale).toInt(), true)
        return ByteArrayOutputStream().also { bmp!!.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
    }

    private fun videoFrame(uri: Uri, px: Int): Bitmap? {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(app, uri)
            if (Build.VERSION.SDK_INT >= 27) r.getScaledFrameAtTime(1_000_000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, px, px)
            else r.frameAtTime
        } catch (_: Exception) {
            null
        } finally {
            r.release()
        }
    }

    private fun imageSampled(uri: Uri, px: Int): Bitmap? {
        val cr = app.contentResolver
        val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, o) } ?: return null
        if (o.outWidth <= 0) return null
        var sample = 1
        while (maxOf(o.outWidth, o.outHeight) / (sample * 2) >= px) sample *= 2
        val bmp = cr.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val deg = try {
            cr.openInputStream(uri)?.use {
                when (ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1)) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
            } ?: 0f
        } catch (_: Exception) {
            0f
        }
        return if (deg == 0f) bmp
        else Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, Matrix().apply { postRotate(deg) }, true)
    }

    private fun view(path: String, action: String) {
        val content = path.startsWith("content:")
        val f = File(path.removePrefix("file:"))
        val uri = if (content) Uri.parse(path) else FileProvider.getUriForFile(app, "${app.packageName}.files", f)
        val mime = (if (content) app.contentResolver.getType(uri) else null)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase()) ?: "*/*"
        val i = Intent(action).apply {
            if (action == Intent.ACTION_SEND) {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
            } else {
                setDataAndType(uri, mime)
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        app.startActivity(Intent.createChooser(i, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }

    @Suppress("DEPRECATION")
    private fun transferLocks(on: Boolean) {
        if (on) {
            if (wake == null) {
                wake = (app.getSystemService(Context.POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DropMate:transfer").apply { acquire(6 * 60 * 60 * 1000L) }
            }
            if (wifi == null) {
                val wm = app.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= 29) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
                wifi = wm.createWifiLock(mode, "DropMate:transfer").apply { acquire() }
            }
        } else {
            wake?.let { if (it.isHeld) it.release() }
            wifi?.let { if (it.isHeld) it.release() }
            wake = null
            wifi = null
        }
    }

    private fun multicastLock(on: Boolean) {
        val wm = app.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (on && multicast == null) {
            multicast = wm.createMulticastLock("DropMate:discovery").apply { setReferenceCounted(false); acquire() }
        } else if (!on) {
            multicast?.release()
            multicast = null
        }
    }
}
