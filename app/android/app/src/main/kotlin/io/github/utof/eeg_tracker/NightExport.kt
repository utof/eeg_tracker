package io.github.utof.eeg_tracker

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Export of one night: the owner picks a folder with the system picker (Storage Access Framework,
 * ACTION_OPEN_DOCUMENT_TREE), and the night's files are copied from the app's private folder into a new
 * subfolder there. Nothing leaves the private folder without this step (DECISIONS, phone file location).
 */
class NightExport(
    private val files: List<File>,
    private val folderName: String,
    val result: MethodChannel.Result,
) {
    companion object {
        const val CHANNEL = "eeg_tracker/export"
        const val REQUEST = 4712

        // Keeps the names exactly (".f32", ".idx", ".log"): a typed MIME type could add an extension.
        private const val MIME = "application/octet-stream"

        /** Only files of the recordings folder may be exported (a wrong path from Dart is refused). */
        fun checkedFiles(context: Context, paths: List<String>): List<File> {
            val root = PhoneChannel.recordingsFolder(context).canonicalPath + File.separator
            return paths.map { p ->
                val f = File(p).canonicalFile
                if (!f.path.startsWith(root) || !f.isFile) throw IOException("not a recording: $p")
                f
            }
        }
    }

    /** Copies on a background thread; the result (files, bytes, folder) goes back on the main thread. */
    fun copyInBackground(context: Context, tree: Uri) {
        val main = Handler(Looper.getMainLooper())
        Thread {
            try {
                val done = copy(context, tree)
                main.post { result.success(done) }
            } catch (e: Exception) {
                main.post { result.error("export", e.message ?: e.javaClass.simpleName, null) }
            }
        }.start()
    }

    private fun copy(context: Context, tree: Uri): Map<String, Any> {
        val resolver = context.contentResolver
        val picked = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val folder = DocumentsContract.createDocument(
            resolver, picked, DocumentsContract.Document.MIME_TYPE_DIR, folderName,
        ) ?: throw IOException("could not create the folder $folderName")
        var bytes = 0L
        for (f in files) {
            val doc = DocumentsContract.createDocument(resolver, folder, MIME, f.name)
                ?: throw IOException("could not create ${f.name}")
            val out = resolver.openOutputStream(doc) ?: throw IOException("could not write ${f.name}")
            val n = out.use { o -> f.inputStream().use { it.copyTo(o, 1 shl 16) } }
            if (n != f.length()) throw IOException("${f.name}: copied $n of ${f.length()} bytes")
            bytes += n
        }
        return mapOf("files" to files.size, "bytes" to bytes, "folder" to folderName)
    }
}
