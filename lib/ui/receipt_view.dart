import 'dart:io';

import 'package:flutter/material.dart';

import '../io/receipts.dart';
import '../l10n/strings.dart';

/// The receipt's photo, full screen; on another device it says where the picture is.
Future<void> showReceipt(BuildContext context, String name) async {
  final File? file = await receiptFile(name);
  if (!context.mounted) return;
  if (file == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('rc_elsewhere'))));
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (c) => Scaffold(
      appBar: AppBar(title: Text(tr('rc_title'))),
      body: InteractiveViewer(maxScale: 5, child: Center(child: Image.file(file))),
    ),
  ));
}
