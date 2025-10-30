package com.example.myapp

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import androidx.core.content.edit
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import android.os.Bundle

class MainActivity : FlutterActivity() {
	private var navChannel: MethodChannel? = null
	private var appChannel: MethodChannel? = null

	override fun provideFlutterEngine(context: Context): FlutterEngine? {
		// Attach to the pre-warmed engine if available
		return FlutterEngineCache.getInstance().get("warm_engine")
	}

	override fun shouldDestroyEngineWithHost(): Boolean {
		// Keep engine alive across activity recreation
		return false
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		navChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.myapp/navigation")
			appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.myapp/app")
			appChannel?.setMethodCallHandler { call, result ->
				when (call.method) {
					"clearBadge" -> {
						clearBadge()
						result.success(null)
					}
					"startMessageWatcher" -> {
						try {
							MessageWatcherService.start(this)
							result.success(null)
						} catch (e: Throwable) {
							result.error("START_FAIL", e.message, null)
						}
					}
					"stopMessageWatcher" -> {
						try {
							MessageWatcherService.stop(this)
							result.success(null)
						} catch (e: Throwable) {
							result.error("STOP_FAIL", e.message, null)
						}
					}
					else -> result.notImplemented()
				}
			}
	}

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		// Handle conversation deep link if activity started from notification
		maybeSendConv(intent)
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		maybeSendConv(intent)
	}

	override fun onPostResume() {
		super.onPostResume()
		maybeSendConv(intent)
	}

	private fun maybeSendConv(intent: Intent?) {
		val conv = intent?.getStringExtra("conv")
		if (!conv.isNullOrEmpty()) {
			navChannel?.invokeMethod("openConversation", mapOf("conversationId" to conv))
			intent?.removeExtra("conv")
		}
	}

	private fun clearBadge() {
		try {
			val prefs: SharedPreferences = getSharedPreferences("app_badge", Context.MODE_PRIVATE)
			prefs.edit(commit = true) { putInt("unread", 0) }
			val nm = getSystemService(Context.NOTIFICATION_SERVICE) as android.app.NotificationManager
			nm.cancelAll()
		} catch (_: Throwable) {}
	}
}

