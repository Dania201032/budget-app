package app.budget.budget_app.capture

import android.content.Context
import android.net.Uri
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.io.File

/**
 * A photo of a receipt, read on the phone: its QR code (Russian receipts carry the tax service's
 * one with the total and the time) and its text. lib/capture/receipt.dart makes sense of both.
 */
object ReceiptScanner {
    /** {text, qr} of the picture at [path] (blocking: call off the main thread). */
    fun scan(ctx: Context, path: String): Map<String, Any?> {
        val image = InputImage.fromFilePath(ctx, Uri.fromFile(File(path)))
        val qr = runCatching {
            val scanner = BarcodeScanning.getClient(
                BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build(),
            )
            try {
                val codes = Tasks.await(scanner.process(image)).mapNotNull { it.rawValue }
                codes.firstOrNull { it.contains("fn=") } ?: codes.firstOrNull()
            } finally {
                scanner.close()
            }
        }.getOrNull()
        val text = runCatching { SharedInput.readImage(image) }.getOrNull()
        return mapOf("text" to text, "qr" to qr)
    }
}
