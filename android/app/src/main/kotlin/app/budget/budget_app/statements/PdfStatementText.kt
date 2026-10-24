package app.budget.budget_app.statements

import android.content.Context
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper

/**
 * Text of a bank statement PDF (Sber, VTB, T-Bank give statements only as PDF), read on the phone:
 * the file never leaves it. Sorted by position, so each table row of the statement is one line
 * (see lib/import/pdf_statement.dart).
 */
object PdfStatementText {
    @Volatile private var ready = false

    fun read(context: Context, bytes: ByteArray, password: String?): String {
        if (!ready) {
            PDFBoxResourceLoader.init(context.applicationContext)
            ready = true
        }
        PDDocument.load(bytes, password ?: "").use { doc ->
            val stripper = PDFTextStripper()
            stripper.sortByPosition = true
            return stripper.getText(doc)
        }
    }
}
