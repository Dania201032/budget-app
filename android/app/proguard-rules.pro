# PDFBox (bank statement PDFs): optional JPEG 2000 support is not included; its fonts and
# glyph lists are loaded by name.
-dontwarn com.gemalto.jp2.**
-keep class com.tom_roush.pdfbox.** { *; }
-keep class com.tom_roush.fontbox.** { *; }
-keep class com.tom_roush.harmony.** { *; }
