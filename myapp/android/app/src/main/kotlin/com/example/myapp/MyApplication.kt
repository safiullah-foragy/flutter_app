package com.example.myapp

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

class MyApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // Ensure the default FCM channel exists even when app is not running
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val nm = getSystemService(NotificationManager::class.java)
                val channelId = "messages"
                if (nm.getNotificationChannel(channelId) == null) {
                    val ch = NotificationChannel(
                        channelId,
                        "Messages",
                        NotificationManager.IMPORTANCE_HIGH
                    )
                    nm.createNotificationChannel(ch)
                }
            } catch (_: Throwable) {}
        }
        try {
            // If an engine is already cached, don't create another
            val cache = FlutterEngineCache.getInstance()
            val existing = cache.get("warm_engine")
            if (existing == null) {
                val engine = FlutterEngine(this)
                // Plugins will be auto-registered by Flutter when activity attaches if needed.
                // Avoid manual double registration; GeneratedPluginRegistrant is optional with new embedding.
                try {
                    GeneratedPluginRegistrant.registerWith(engine)
                } catch (_: Throwable) {}
            // Start Dart isolate now so it's warm when Activity attaches
                engine.dartExecutor.executeDartEntrypoint(
                    DartExecutor.DartEntrypoint.createDefault()
                )
                cache.put("warm_engine", engine)
            }
        } catch (_: Throwable) {
            // Best-effort; app still works without cached engine
        }
    }
}
