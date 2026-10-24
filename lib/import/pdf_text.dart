import 'package:flutter/services.dart';

import '../platform.dart';
import 'statement.dart';

const _channel = MethodChannel('budget/statement');

/// The text of a PDF statement, read on the phone by PDFBox with each table row on one line
/// (android/…/statements/PdfStatementText.kt). The computer can't read PDFs: import them on the
/// phone, sync brings the operations over.
Future<String> pdfText(Uint8List bytes) async {
  if (appIsDesktop) throw const UnknownStatement('pdf_desktop');
  try {
    return await _channel.invokeMethod<String>('pdfText', {'bytes': bytes}) ?? '';
  } on PlatformException catch (e) {
    throw UnknownStatement('pdf: ${e.message}');
  } on MissingPluginException {
    throw const UnknownStatement('pdf_desktop');
  }
}
