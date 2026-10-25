package app.budget.budget_app.capture

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions

/**
 * "Share → Budget": an SMS, a notification's text or a payment screenshot sent to the app. The
 * Dart side finds the amount (lib/capture/shared_text.dart) and opens the editor with it.
 * Screenshots are read on the phone (ML Kit, Chinese and Latin script, no internet).
 */
object SharedInput {
    /** The shared content of [intent] as a pending action for the Dart side, once. */
    fun actionFrom(intent: Intent?): Map<String, Any>? {
        if (intent?.action != Intent.ACTION_SEND) return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val image = streamOf(intent)
        intent.action = null // not again when the activity is recreated
        return when {
            image != null && intent.type?.startsWith("image/") == true -> mapOf("type" to "share_image", "uri" to image.toString())
            !text.isNullOrBlank() -> mapOf("type" to "share", "text" to text)
            else -> null
        }
    }

    private fun streamOf(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    /** The text in a picture, line by line (blocking: call off the main thread). */
    fun readImage(ctx: Context, uri: Uri): String = readImage(InputImage.fromFilePath(ctx, uri))

    fun readImage(image: InputImage): String {
        val recognizer = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
        try {
            val result = Tasks.await(recognizer.process(image))
            return result.textBlocks.joinToString("\n") { b -> b.lines.joinToString("\n") { it.text } }
        } finally {
            recognizer.close()
        }
    }
}
