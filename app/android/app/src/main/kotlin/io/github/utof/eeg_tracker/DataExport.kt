package io.github.utof.eeg_tracker

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Export data (DECISIONS rows 150-154): copies the app's private files into the folder the owner picked once with
 * the system picker (ACTION_OPEN_DOCUMENT_TREE), keeping that grant across restarts (takePersistableUriPermission).
 * Dart decides what to copy (lib/export/); this class only finds or creates `eeg-export/<path>` under the grant,
 * replaces the file's contents and returns the bytes written and their SHA-256, worked out while copying. Every
 * call runs on one background thread, in order. Only files inside the app's own files folder can be sent.
 */
class DataExport(private val context: Context) {
    companion object {
        const val REQUEST = 4713
        const val FOLDER = "eeg-export"

        // Keeps the names exactly: a typed MIME type could add an extension (as NightExport.kt).
        private const val MIME = "application/octet-stream"
        private const val GRANT = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

        fun pickIntent(): Intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
            GRANT or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
        )

        /** `Download/EEG` for a folder on the phone's own storage, `<volume>: EEG` elsewhere. */
        fun label(tree: Uri): String {
            val id = DocumentsContract.getTreeDocumentId(tree)
            val colon = id.indexOf(':')
            val volume = if (colon >= 0) id.substring(0, colon) else ""
            val path = if (colon >= 0) id.substring(colon + 1) else id
            return when {
                volume == "primary" || volume.isEmpty() -> path.ifEmpty { "phone storage" }
                else -> "$volume: ${path.ifEmpty { "/" }}"
            }
        }

        private fun hex(b: ByteArray): String = b.joinToString("") { "%02x".format(it) }
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var tree: Uri? = null
    private val dirs = HashMap<String, String>() // folder path in the export -> document id
    private val listed = HashMap<String, HashMap<String, String>>() // folder document id -> name -> document id

    /** Keeps the grant for [picked] and lets go of older export grants (Android caps how many an app may keep). */
    fun keep(picked: Uri): Map<String, String> {
        val resolver = context.contentResolver
        resolver.takePersistableUriPermission(picked, GRANT)
        for (p in resolver.persistedUriPermissions) {
            if (p.uri != picked) runCatching { resolver.releasePersistableUriPermission(p.uri, GRANT) }
        }
        return mapOf("uri" to picked.toString(), "label" to label(picked))
    }

    /** Whether the app still holds write access to [uri] (the owner can take it back in the phone's settings). */
    fun usable(uri: String): Boolean =
        context.contentResolver.persistedUriPermissions.any { it.uri.toString() == uri && it.isWritePermission }

    /** Runs [work] on the export thread and answers on the main thread. */
    fun run(result: MethodChannel.Result, work: () -> Any?) {
        worker.execute {
            try {
                val v = work()
                main.post { result.success(v) }
            } catch (e: SecurityException) {
                main.post { result.error("folder", "the app may no longer write there: pick the folder again", null) }
            } catch (e: FileNotFoundException) {
                main.post { result.error("folder", "the folder is gone: pick it again (${e.message})", null) }
            } catch (e: Exception) {
                main.post { result.error("export", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    fun open(uri: String) {
        if (!usable(uri)) throw SecurityException("no grant")
        val t = Uri.parse(uri)
        tree = t
        dirs.clear()
        listed.clear()
        dirs[""] = folder(DocumentsContract.getTreeDocumentId(t), FOLDER)
    }

    fun close() {
        tree = null
        dirs.clear()
        listed.clear()
    }

    private fun treeUri(): Uri = tree ?: throw IOException("the export folder is not open")

    private fun children(dirId: String): HashMap<String, String> = listed.getOrPut(dirId) {
        val map = HashMap<String, String>()
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri(), dirId)
        val cols = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME)
        val c = context.contentResolver.query(uri, cols, null, null, null)
            ?: throw FileNotFoundException("cannot list the folder")
        c.use { while (it.moveToNext()) map[it.getString(1)] = it.getString(0) }
        map
    }

    /** The document id of folder [name] in [parentId], made when missing. */
    private fun folder(parentId: String, name: String): String {
        children(parentId)[name]?.let { return it }
        val made = DocumentsContract.createDocument(
            context.contentResolver, DocumentsContract.buildDocumentUriUsingTree(treeUri(), parentId),
            Document.MIME_TYPE_DIR, name,
        ) ?: throw IOException("could not create the folder $name")
        val id = DocumentsContract.getDocumentId(made)
        children(parentId)[name] = id
        return id
    }

    private fun dirId(path: String): String = if (path.isEmpty()) {
        dirs[""] ?: throw IOException("the export folder is not open")
    } else dirs.getOrPut(path) {
        val slash = path.lastIndexOf('/')
        folder(dirId(if (slash < 0) "" else path.substring(0, slash)), path.substring(slash + 1))
    }

    private fun checkedPath(path: String): String {
        val parts = path.split('/')
        if (path.startsWith("/") || path.contains('\\') || parts.any { it.isEmpty() || it == "." || it == ".." }) {
            throw IOException("not a path inside the export folder: $path")
        }
        return path
    }

    /** The document for [path], made when missing. */
    private fun document(path: String): Uri {
        val p = checkedPath(path)
        val slash = p.lastIndexOf('/')
        val dir = dirId(if (slash < 0) "" else p.substring(0, slash))
        val name = p.substring(slash + 1)
        val have = children(dir)[name]
        if (have != null) return DocumentsContract.buildDocumentUriUsingTree(treeUri(), have)
        val made = DocumentsContract.createDocument(
            context.contentResolver, DocumentsContract.buildDocumentUriUsingTree(treeUri(), dir), MIME, name,
        ) ?: throw IOException("could not create $p")
        children(dir)[name] = DocumentsContract.getDocumentId(made)
        return made
    }

    /** Replaces [path]'s contents with [input]; returns the bytes written and their SHA-256. */
    private fun send(path: String, input: InputStream): Map<String, Any> {
        val doc = document(path)
        val md = MessageDigest.getInstance("SHA-256")
        var n = 0L
        val out = context.contentResolver.openOutputStream(doc, "wt") ?: throw IOException("could not write $path")
        out.use { o ->
            input.use { i ->
                val buf = ByteArray(1 shl 16)
                while (true) {
                    val r = i.read(buf)
                    if (r < 0) break
                    md.update(buf, 0, r)
                    o.write(buf, 0, r)
                    n += r
                }
            }
        }
        val held = size(doc)
        if (held != null && held != n) throw IOException("$path: wrote $n bytes but the folder holds $held")
        return mapOf("bytes" to n, "sha256" to hex(md.digest()))
    }

    private fun size(doc: Uri): Long? =
        context.contentResolver.query(doc, arrayOf(Document.COLUMN_SIZE), null, null, null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null
        }

    /** Copies a file of the app's own folder; anything outside it is refused. */
    fun copy(source: String, path: String): Map<String, Any> {
        val root = context.filesDir.canonicalPath + File.separator
        val f = File(source).canonicalFile
        if (!f.path.startsWith(root) || !f.isFile) throw IOException("not a file of the app: $source")
        return send(path, f.inputStream())
    }

    fun write(path: String, bytes: ByteArray): Map<String, Any> = send(path, bytes.inputStream())
}
