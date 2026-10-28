package app.budget.budget_app

import android.Manifest
import android.app.Activity
import android.app.AppOpsManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Bundle
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import app.budget.budget_app.backup.BackupCrypto
import app.budget.budget_app.backup.BackupKeys
import app.budget.budget_app.backup.BackupStore
import app.budget.budget_app.backup.SyncFolderStore
import app.budget.budget_app.capture.BankLog
import app.budget.budget_app.capture.CaptureInbox
import app.budget.budget_app.capture.PaymentAccessibilityService
import app.budget.budget_app.capture.PaymentNotificationListener
import app.budget.budget_app.capture.ReceiptScanner
import app.budget.budget_app.capture.SharedInput
import app.budget.budget_app.capture.SplitActions
import app.budget.budget_app.statements.PdfStatementText
import app.budget.budget_app.widgets.HomeWidgets
import app.budget.budget_app.widgets.WidgetKind
import app.budget.budget_app.widgets.WidgetRefresh
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** A FragmentActivity: the fingerprint / face prompt of the app lock (local_auth) needs one. */
class MainActivity : FlutterFragmentActivity() {

    private companion object {
        const val REQ_PICK_FOLDER = 41
        const val REQ_PICK_FILE = 42
        const val REQ_CAMERA = 43
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pendingResult: MethodChannel.Result? = null
    private var pendingAction: Map<String, Any>? = null

    /** Where the camera writes a receipt photo ("takeReceiptPhoto"). */
    private var cameraFile: java.io.File? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingAction = SplitActions.pendingFrom(intent) ?: HomeWidgets.actionFrom(intent) ?: SharedInput.actionFrom(intent)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "budget/capture").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(
                    mapOf(
                        "accessibility" to isEnabled("enabled_accessibility_services", PaymentAccessibilityService::class.java),
                        "notifications" to isEnabled("enabled_notification_listeners", PaymentNotificationListener::class.java),
                        "postNotifications" to canPostNotifications(),
                        // Android 13+ blocks both special accesses for apps installed from a file
                        // ("Restricted settings") until the user allows it in App info.
                        "sdk" to Build.VERSION.SDK_INT,
                        "restricted" to restrictedSettings(),
                    )
                )
                "consumeInbox" -> result.success(CaptureInbox.consume(this))
                "bankLog" -> result.success(BankLog.read(this))
                "clearBankLog" -> {
                    BankLog.clear(this)
                    result.success(null)
                }
                "openAccessibility" -> openFirst(result, accessibilityIntents())
                "openNotificationAccess" -> openFirst(result, notificationAccessIntents())
                "openAppInfo" -> open(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")),
                    result,
                )
                "requestPostNotifications" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                    }
                    result.success(null)
                }
                "setLanguage" -> {
                    NativeStrings.setLang(this, call.argument<String>("lang") ?: "ru")
                    result.success(null)
                }
                "setReminders" -> {
                    Reminders.set(this, call.argument<String>("json") ?: "[]")
                    result.success(null)
                }
                "takePendingAction" -> {
                    result.success(pendingAction)
                    pendingAction = null
                }
                "scanReceipt" -> background(result) { ReceiptScanner.scan(this, call.argument<String>("path")!!) }
                "takeReceiptPhoto" -> {
                    // The system camera writes into a file of ours, given through the FileProvider.
                    val dir = java.io.File(cacheDir, "receipt_camera").apply { mkdirs() }
                    val file = java.io.File(dir, "shot_${System.currentTimeMillis()}.jpg")
                    val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.receipts", file)
                    cameraFile = file
                    pendingResult = result
                    try {
                        @Suppress("DEPRECATION")
                        startActivityForResult(
                            Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE)
                                .putExtra(android.provider.MediaStore.EXTRA_OUTPUT, uri)
                                .addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION),
                            REQ_CAMERA,
                        )
                    } catch (e: android.content.ActivityNotFoundException) {
                        pendingResult = null
                        result.success(null)
                    }
                }
                "readSharedImage" -> background(result) {
                    SharedInput.readImage(this, Uri.parse(call.argument<String>("uri")!!))
                }
                else -> result.notImplemented()
            }
        }

        // Home-screen widgets: the app sends its figures; rendering happens off the UI thread.
        // While this engine lives, background refreshes (captures, midnight) go through it.
        val widgets = MethodChannel(messenger, "budget/widgets")
        widgets.setMethodCallHandler { call, result ->
            when (call.method) {
                "update" -> {
                    val json = call.argument<String>("json") ?: "{}"
                    io.execute {
                        runCatching { HomeWidgets.update(this, json) }
                        main.post { result.success(null) }
                    }
                }
                "pin" -> result.success(
                    runCatching { HomeWidgets.pin(this, WidgetKind.valueOf(call.argument<String>("kind") ?: "")) }
                        .getOrDefault(false),
                )
                else -> result.notImplemented()
            }
        }
        WidgetRefresh.appChannel = widgets

        MethodChannel(messenger, "budget/backup").setMethodCallHandler { call, result ->
            when (call.method) {
                "pickFolder" -> {
                    pendingResult = result
                    @Suppress("DEPRECATION")
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_PICK_FOLDER)
                }
                "pickFile" -> {
                    pendingResult = result
                    val i = Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                    @Suppress("DEPRECATION")
                    startActivityForResult(i, REQ_PICK_FILE)
                }
                "folderName" -> background(result) { BackupStore.folderName(this, Uri.parse(call.argument<String>("uri"))) }
                "write" -> background(result) {
                    val tree = Uri.parse(call.argument<String>("uri"))
                    val packed = BackupKeys.pack(this, call.argument<ByteArray>("bytes")!!)
                    BackupStore.write(this, tree, call.argument<String>("name")!!, packed)
                    BackupStore.prune(this, tree, call.argument<Int>("keep") ?: 20)
                    mapOf("size" to packed.size, "encrypted" to BackupKeys.has(this))
                }
                // Encrypted backup file in the cache, to send via the share sheet ("Save to Drive" etc.).
                "packToCache" -> background(result) {
                    val packed = BackupKeys.pack(this, call.argument<ByteArray>("bytes")!!)
                    BackupStore.cacheCopy(this, call.argument<String>("name")!!, packed).absolutePath
                }
                "setPassword" -> background(result) {
                    BackupKeys.setPassword(this, call.argument<String>("password"))
                    BackupKeys.has(this)
                }
                "hasPassword" -> background(result) { BackupKeys.has(this) }
                // Google Drive (by default) uploads only over Wi-Fi: the app warns when on mobile data.
                "connection" -> {
                    val cm = getSystemService(android.net.ConnectivityManager::class.java)
                    val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                    val wifi = caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true ||
                        caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) == true
                    result.success(
                        mapOf("wifi" to wifi, "provider" to (call.argument<String>("uri")?.let { Uri.parse(it).authority } ?: ""))
                    )
                }
                "checkPassword" -> background(result) { BackupKeys.check(this, call.argument<String>("password") ?: "") }
                "list" -> background(result) { BackupStore.list(this, Uri.parse(call.argument<String>("uri"))) }
                "readFromFolder" -> background(result) {
                    BackupStore.read(this, Uri.parse(call.argument<String>("uri")), call.argument<String>("name")!!)
                }
                "isEncrypted" -> background(result) { BackupCrypto.isEncrypted(call.argument<ByteArray>("bytes")!!) }
                "unpack" -> background(result) {
                    BackupCrypto.unpack(call.argument<ByteArray>("bytes")!!, call.argument<String>("password"))
                }
                else -> result.notImplemented()
            }
        }

        // Sync with the computer through a cloud folder (lib/sync/sync_folder.dart).
        MethodChannel(messenger, "budget/sync").setMethodCallHandler { call, result ->
            val tree = call.argument<String>("uri")?.let(Uri::parse)
            when (call.method) {
                "pickFolder" -> {
                    pendingResult = result
                    @Suppress("DEPRECATION")
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_PICK_FOLDER)
                }
                "list" -> background(result) { SyncFolderStore.list(this, tree!!) }
                "read" -> background(result) { SyncFolderStore.read(this, tree!!, call.argument<String>("name")!!) }
                "write" -> background(result) {
                    SyncFolderStore.write(this, tree!!, call.argument<String>("name")!!, call.argument<ByteArray>("bytes")!!)
                    null
                }
                "delete" -> background(result) { SyncFolderStore.delete(this, tree!!, call.argument<String>("name")!!) }
                else -> result.notImplemented()
            }
        }

        // Bank statements given as PDF (lib/import/pdf_text.dart).
        MethodChannel(messenger, "budget/statement").setMethodCallHandler { call, result ->
            when (call.method) {
                "pdfText" -> background(result) {
                    PdfStatementText.read(this, call.argument<ByteArray>("bytes")!!, call.argument<String>("password"))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        WidgetRefresh.appChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        (SplitActions.pendingFrom(intent) ?: HomeWidgets.actionFrom(intent) ?: SharedInput.actionFrom(intent))?.let { pendingAction = it }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        val result = pendingResult ?: return
        pendingResult = null
        if (requestCode == REQ_CAMERA) {
            val file = cameraFile
            cameraFile = null
            result.success(if (resultCode == Activity.RESULT_OK && file != null && file.length() > 0) file.path else null)
            return
        }
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        when (requestCode) {
            REQ_PICK_FOLDER -> {
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
                background(result) { mapOf("uri" to uri.toString(), "name" to (BackupStore.folderName(this, uri) ?: "")) }
            }
            REQ_PICK_FILE -> background(result) { BackupStore.readUri(this, uri) }
            else -> result.success(null)
        }
    }

    /** File and crypto work off the UI thread; errors go back to Dart as PlatformException. */
    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("backup", e.message ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun canPostNotifications(): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun isEnabled(settingKey: String, cls: Class<*>): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, settingKey) ?: return false
        val component = ComponentName(this, cls)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == component }
    }

    private fun open(intent: Intent, result: MethodChannel.Result) {
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        result.success(null)
    }

    /** Tries the intents in order (the most precise first); some phones lack or forbid one. */
    private fun openFirst(result: MethodChannel.Result, intents: List<Intent>) {
        for (i in intents) {
            try {
                startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
                return
            } catch (e: ActivityNotFoundException) {
            } catch (e: SecurityException) {
            }
        }
        result.success(null)
    }

    /**
     * The switch of this app's accessibility service itself, so nobody has to find it in a list
     * whose name differs on every phone (Samsung: "Installed apps", Pixel: "Downloaded apps"…).
     * Older phones: the list, with this app's row highlighted where the Settings app supports it.
     */
    private fun accessibilityIntents(): List<Intent> {
        val component = ComponentName(this, PaymentAccessibilityService::class.java).flattenToString()
        val highlight = Bundle().apply { putString(":settings:fragment_args_key", component) }
        return listOfNotNull(
            if (Build.VERSION.SDK_INT >= 31) {
                Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS").putExtra(Intent.EXTRA_COMPONENT_NAME, component)
            } else {
                null
            },
            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                .putExtra(":settings:fragment_args_key", component)
                .putExtra(":settings:show_fragment_args", highlight),
        )
    }

    /** The notification-access switch of this app itself (Android 11+), else the list. */
    private fun notificationAccessIntents(): List<Intent> {
        val component = ComponentName(this, PaymentNotificationListener::class.java).flattenToString()
        return listOfNotNull(
            if (Build.VERSION.SDK_INT >= 30) {
                Intent("android.settings.NOTIFICATION_LISTENER_DETAIL_SETTINGS")
                    .putExtra("android.provider.extra.NOTIFICATION_LISTENER_COMPONENT_NAME", component)
            } else {
                null
            },
            Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS"),
        )
    }

    /**
     * Android 13+ greys out the special accesses of an app installed from a file (Telegram, a
     * browser, a file manager) until "Allow restricted settings" in App info. True while that
     * still applies to this app; the screen then leads through lifting it first.
     */
    private fun restrictedSettings(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return false
        val fromFile = try {
            val source = packageManager.getInstallSourceInfo(packageName).packageSource
            source == PackageInstaller.PACKAGE_SOURCE_LOCAL_FILE || source == PackageInstaller.PACKAGE_SOURCE_DOWNLOADED_FILE
        } catch (e: Exception) {
            false
        }
        if (!fromFile) return false
        return try {
            val ops = getSystemService(APP_OPS_SERVICE) as AppOpsManager
            ops.unsafeCheckOpNoThrow("android:access_restricted_settings", applicationInfo.uid, packageName) != AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            true
        }
    }
}
