package app.budget.budget_app.backup

import android.content.Context
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import androidx.documentfile.provider.DocumentFile
import java.nio.ByteBuffer
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Backups in a user-chosen folder (Storage Access Framework): any cloud app that exposes a document
 * provider works — OneDrive, Google Drive, Yandex Disk, Baidu, Dropbox… The cloud app uploads the file.
 *
 * Every backup is a NEW file (budget-backup-2026-10-13_203300.bkp): cloud providers handle
 * "create + write once" reliably, while overwriting through SAF is flaky (Google Drive in particular).
 */
object BackupStore {
    const val PREFIX = "budget-backup-"

    fun folderName(ctx: Context, tree: Uri): String? = DocumentFile.fromTreeUri(ctx, tree)?.name

    /**
     * Writes and verifies by reading the file back (providers like Google Drive report size 0 until
     * the upload finishes, so the reported size alone is not reliable). Throws with details on failure.
     */
    fun write(ctx: Context, tree: Uri, name: String, bytes: ByteArray) {
        val dir = DocumentFile.fromTreeUri(ctx, tree) ?: error("folder not available (${tree.authority})")
        dir.findFile(name)?.delete()
        val file = dir.createFile("application/octet-stream", name) ?: error("cannot create $name in ${tree.authority}")
        var lastError: Exception? = null
        for (mode in listOf("w", "wt", "rwt")) {
            try {
                ctx.contentResolver.openOutputStream(file.uri, mode)!!.use {
                    it.write(bytes)
                    it.flush()
                }
                val back = try {
                    ctx.contentResolver.openInputStream(file.uri)?.use { it.readBytes().size } ?: -1
                } catch (e: Exception) {
                    -1
                }
                val reported = DocumentFile.fromSingleUri(ctx, file.uri)?.length() ?: -1
                Log.i(TAG, "write $name to ${tree.authority} mode=$mode bytes=${bytes.size} readBack=$back reported=$reported")
                if (back == bytes.size || reported == bytes.size.toLong()) return
                // Could not read back (some providers only allow it after upload): trust a non-failing write
                // unless the provider explicitly reports an empty file.
                if (back == -1 && reported != 0L) return
                lastError = IllegalStateException("${tree.authority}: wrote ${bytes.size} bytes, read back $back, reported $reported")
            } catch (e: Exception) {
                Log.w(TAG, "write $name mode=$mode failed", e)
                lastError = e
            }
        }
        file.delete()
        throw lastError ?: IllegalStateException("write failed")
    }

    /** Copy of the backup in the app cache, for "Send a copy…" (share sheet). */
    fun cacheCopy(ctx: Context, name: String, bytes: ByteArray): java.io.File {
        val dir = java.io.File(ctx.cacheDir, "backup").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        return java.io.File(dir, name).apply { writeBytes(bytes) }
    }

    private const val TAG = "BudgetBackup"

    fun list(ctx: Context, tree: Uri): List<Map<String, Any>> {
        val dir = DocumentFile.fromTreeUri(ctx, tree) ?: return emptyList()
        return dir.listFiles()
            .filter { it.isFile && (it.name ?: "").startsWith(PREFIX) }
            .sortedByDescending { it.name }
            .map { mapOf("name" to (it.name ?: ""), "modified" to it.lastModified(), "size" to it.length()) }
    }

    fun read(ctx: Context, tree: Uri, name: String): ByteArray {
        val dir = DocumentFile.fromTreeUri(ctx, tree) ?: error("folder not available")
        val file = dir.findFile(name) ?: error("$name not found")
        return ctx.contentResolver.openInputStream(file.uri)!!.use { it.readBytes() }
    }

    fun readUri(ctx: Context, uri: Uri): ByteArray =
        ctx.contentResolver.openInputStream(uri)!!.use { it.readBytes() }

    /** Keeps the newest [keep] backups. */
    fun prune(ctx: Context, tree: Uri, keep: Int) {
        val dir = DocumentFile.fromTreeUri(ctx, tree) ?: return
        dir.listFiles().filter { it.isFile && (it.name ?: "").startsWith(PREFIX) }
            .sortedByDescending { it.name }
            .drop(keep)
            .forEach { it.delete() }
    }
}

/**
 * File format: "BDGT" | version(1) | encrypted(1) | [salt(16) | iv(12)] | payload.
 * Encrypted payload = AES-256-GCM, key = PBKDF2-HMAC-SHA256(password, salt, 120 000).
 */
object BackupCrypto {
    private val MAGIC = "BDGT".toByteArray()
    private const val VERSION: Byte = 1
    private const val ITERATIONS = 120_000

    fun newSalt(): ByteArray = ByteArray(16).also(SecureRandom()::nextBytes)

    fun deriveKey(password: String, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(password.toCharArray(), salt, ITERATIONS, 256)
        return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
    }

    fun packPlain(payload: ByteArray): ByteArray =
        ByteBuffer.allocate(6 + payload.size).put(MAGIC).put(VERSION).put(0).put(payload).array()

    /** Encrypts with an already derived key; [salt] is stored so the password can re-derive it. */
    fun packWithKey(payload: ByteArray, key: ByteArray, salt: ByteArray): ByteArray {
        val iv = ByteArray(12).also(SecureRandom()::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        val enc = cipher.doFinal(payload)
        return ByteBuffer.allocate(6 + 16 + 12 + enc.size).put(MAGIC).put(VERSION).put(1).put(salt).put(iv).put(enc).array()
    }

    fun pack(payload: ByteArray, password: String?): ByteArray {
        if (password.isNullOrEmpty()) return packPlain(payload)
        val salt = newSalt()
        return packWithKey(payload, deriveKey(password, salt), salt)
    }

    /** Whether the file needs a password. */
    fun isEncrypted(data: ByteArray): Boolean {
        check(data.size >= 6 && data.copyOfRange(0, 4).contentEquals(MAGIC)) { "not a backup file" }
        return data[5].toInt() == 1
    }

    /** Throws on a wrong password (GCM tag mismatch). */
    fun unpack(data: ByteArray, password: String?): ByteArray {
        if (!isEncrypted(data)) return data.copyOfRange(6, data.size)
        require(!password.isNullOrEmpty()) { "password required" }
        val salt = data.copyOfRange(6, 22)
        val iv = data.copyOfRange(22, 34)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(deriveKey(password, salt), "AES"), GCMParameterSpec(128, iv))
        return cipher.doFinal(data, 34, data.size - 34)
    }
}

/**
 * The backup password is NOT stored anywhere. Only the key derived from it is kept, itself encrypted
 * by a key in the Android Keystore (hardware-backed where available, never leaves the chip), so
 * automatic backups can be encrypted without asking. Restoring on another phone needs the password.
 */
object BackupKeys {
    private const val PREFS = "budget_backup_key"
    private const val ALIAS = "budget_backup_wrap"

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun unb64(s: String) = Base64.decode(s, Base64.NO_WRAP)

    fun setPassword(ctx: Context, password: String?) {
        if (password.isNullOrEmpty()) {
            prefs(ctx).edit().clear().apply()
            return
        }
        val salt = BackupCrypto.newSalt()
        val key = BackupCrypto.deriveKey(password, salt)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, wrapKey()) }
        val wrapped = cipher.doFinal(key)
        prefs(ctx).edit()
            .putString("salt", b64(salt))
            .putString("iv", b64(cipher.iv))
            .putString("key", b64(wrapped))
            .apply()
    }

    fun has(ctx: Context): Boolean = prefs(ctx).contains("key")

    /** (key, salt) or null when no password is set. */
    fun load(ctx: Context): Pair<ByteArray, ByteArray>? {
        val p = prefs(ctx)
        val salt = p.getString("salt", null) ?: return null
        val iv = p.getString("iv", null) ?: return null
        val wrapped = p.getString("key", null) ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, unb64(iv)))
            cipher.doFinal(unb64(wrapped)) to unb64(salt)
        } catch (e: Exception) {
            // Wrapped by another phone's Keystore or the Keystore was reset: the key is gone, so the
            // app asks for the backup password again instead of failing every backup.
            p.edit().clear().apply()
            null
        }
    }

    /** "Check my password": does it derive the stored key? */
    fun check(ctx: Context, password: String): Boolean {
        val (key, salt) = load(ctx) ?: return false
        return BackupCrypto.deriveKey(password, salt).contentEquals(key)
    }

    fun pack(ctx: Context, payload: ByteArray): ByteArray {
        val (key, salt) = load(ctx) ?: return BackupCrypto.packPlain(payload)
        return BackupCrypto.packWithKey(payload, key, salt)
    }
}
