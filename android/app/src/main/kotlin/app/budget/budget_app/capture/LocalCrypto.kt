package app.budget.budget_app.capture

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Line-by-line encryption of the files the capture services keep on the phone (the inbox of
 * captured payments and the bank notification log): AES-256-GCM with a key that lives in the
 * Android Keystore and never leaves it. Lines written before (plain JSON) are still read.
 */
object LocalCrypto {
    private const val ALIAS = "budget_local_files"
    private const val PREFIX = "e1:"

    @Volatile
    private var cached: SecretKey? = null

    private fun key(): SecretKey {
        cached?.let { return it }
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val key = (ks.getKey(ALIAS, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .build()
                )
            }.generateKey()
        cached = key
        return key
    }

    fun seal(line: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val body = cipher.doFinal(line.toByteArray())
        return PREFIX + Base64.encodeToString(cipher.iv + body, Base64.NO_WRAP)
    }

    /** null when the line can't be read (another phone's key after a transfer). */
    fun open(line: String): String? {
        if (!line.startsWith(PREFIX)) return line
        return runCatching {
            val data = Base64.decode(line.removePrefix(PREFIX), Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data, 0, 12))
            String(cipher.doFinal(data, 12, data.size - 12))
        }.getOrNull()
    }

    /** The plain text of a file of sealed lines. */
    fun openAll(text: String): String =
        text.lineSequence().filter { it.isNotBlank() }.mapNotNull { open(it) }.joinToString("") { it + "\n" }
}
