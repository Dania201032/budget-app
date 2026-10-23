package app.budget.budget_app.backup

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile

/**
 * The sync folder (lib/sync/sync_folder.dart, SafSyncFolder): a folder picked with the system folder
 * picker, usually Google Drive. Only the sync files are touched: the folder's meta file and the
 * devices' encrypted change files. Files are never overwritten in place (see [BackupStore.write]).
 */
object SyncFolderStore {
    private val OURS = Regex("^(budget-sync\\.json|bs-[0-9a-f]{8}-\\d{8}\\.bsync)$")

    private fun dir(ctx: Context, tree: Uri) = DocumentFile.fromTreeUri(ctx, tree) ?: error("folder not available (${tree.authority})")

    fun list(ctx: Context, tree: Uri): List<String> =
        dir(ctx, tree).listFiles().mapNotNull { f -> f.name?.takeIf { f.isFile && OURS.matches(it) } }

    fun read(ctx: Context, tree: Uri, name: String): ByteArray? {
        val file = dir(ctx, tree).findFile(name) ?: return null
        return ctx.contentResolver.openInputStream(file.uri)?.use { it.readBytes() }
    }

    fun write(ctx: Context, tree: Uri, name: String, bytes: ByteArray) {
        require(OURS.matches(name)) { "not a sync file: $name" }
        BackupStore.write(ctx, tree, name, bytes)
    }

    fun delete(ctx: Context, tree: Uri, name: String) {
        if (OURS.matches(name)) dir(ctx, tree).findFile(name)?.delete()
    }
}
