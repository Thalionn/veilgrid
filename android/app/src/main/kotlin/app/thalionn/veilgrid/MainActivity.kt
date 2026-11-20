package app.thalionn.veilgrid

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    // Must match AppLifecycleChannel.channelName on the Dart side.
    private val lifecycleChannel = "app.thalionn.veilgrid/lifecycle"

    // In-app updates distributed through GitHub Releases.
    private val updaterChannel = "app.thalionn.veilgrid/updater"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            lifecycleChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // Send the task to the background instead of finishing the
                // Activity. Finishing tears down the Flutter engine and stops
                // the location foreground service (GH #302); moveTaskToBack
                // keeps the service alive, matching Home-button behaviour.
                "moveTaskToBack" -> result.success(moveTaskToBack(true))
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            updaterChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> {
                    val allowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(allowed)
                }

                // Opens the "install unknown apps" screen for Grid. Doing this
                // in-app is more reliable than relying on the installer's
                // "Settings" shortcut.
                "openInstallSettings" -> {
                    try {
                        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            )
                        } else {
                            Intent(Settings.ACTION_SECURITY_SETTINGS)
                        }
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("settings_failed", e.message, null)
                    }
                }

                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "Missing APK path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(path)
                        if (!file.exists()) {
                            result.error("missing_apk", "APK not found", null)
                            return@setMethodCallHandler
                        }
                        val uri: Uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            file,
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(
                                uri,
                                "application/vnd.android.package-archive",
                            )
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
