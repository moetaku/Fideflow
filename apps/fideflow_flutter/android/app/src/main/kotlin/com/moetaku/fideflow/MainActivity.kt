package com.moetaku.fideflow

import android.os.Build
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fideflow/device")
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceName") {
                    val configured = try {
                        Settings.Global.getString(contentResolver, "device_name")
                    } catch (_: SecurityException) { null }
                    val model = if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) {
                        Build.MODEL
                    } else { "${Build.MANUFACTURER} ${Build.MODEL}" }
                    result.success(configured?.trim()?.takeIf { it.isNotEmpty() } ?: model)
                } else { result.notImplemented() }
            }
    }
}
