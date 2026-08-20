package com.example.myapp

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Bundle
import androidx.core.content.edit
import com.google.firebase.FirebaseApp
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private var navChannel: MethodChannel? = null
	private var appChannel: MethodChannel? = null
	private var pendingCallData: Map<String, Any>? = null
	private var pendingConvId: String? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		navChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.myapp/navigation")
		appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.myapp/app")

		navChannel?.setMethodCallHandler { call, result ->
			when (call.method) {
				"getPendingCall" -> {
					val data = pendingCallData
					pendingCallData = null
					result.success(data)
				}
				"getPendingConv" -> {
					val conv = pendingConvId
					pendingConvId = null
					result.success(conv)
				}
				else -> result.notImplemented()
			}
		}

		appChannel?.setMethodCallHandler { call, result ->
			when (call.method) {
				"clearBadge" -> {
					clearBadge()
					result.success(null)
				}
				"startMessageWatcher" -> {
					try {
						MessageWatcherService.start(this)
					} catch (_: Throwable) {}
					result.success(null)
				}
				"stopMessageWatcher" -> {
					try {
						MessageWatcherService.stop(this)
					} catch (_: Throwable) {}
					result.success(null)
				}
				"startCallForeground" -> {
					try {
						val title = (call.argument<String>("title")) ?: "Ongoing call"
						val text = (call.argument<String>("text")) ?: ""
						val video = (call.argument<Boolean>("video")) ?: false
						CallForegroundService.start(this, title, text, video)
						result.success(null)
					} catch (e: Throwable) {
						result.error("CALL_FG_START_FAIL", e.message, null)
					}
				}
				"stopCallForeground" -> {
					try {
						CallForegroundService.stop(this)
						result.success(null)
					} catch (e: Throwable) {
						result.error("CALL_FG_STOP_FAIL", e.message, null)
					}
				}
				else -> result.notImplemented()
			}
		}
	}

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		maybeSendConv(intent)
	}

	override fun onNewIntent(intent: Intent) {
		super.onNewIntent(intent)
		setIntent(intent)
		maybeSendConv(intent)
	}

	override fun onPostResume() {
		super.onPostResume()
		maybeSendConv(intent)
	}

	private fun maybeSendConv(intent: Intent?) {
		val conv = intent?.getStringExtra("conv")
		if (!conv.isNullOrEmpty()) {
			pendingConvId = conv
			navChannel?.invokeMethod("openConversation", mapOf("conversationId" to conv))
			intent?.removeExtra("conv")
		}
		maybeSendCall(intent)
	}

	private fun maybeSendCall(intent: Intent?) {
		val channel = intent?.getStringExtra("call_channel")
		val callerId = intent?.getStringExtra("caller_id")
		val callerName = intent?.getStringExtra("caller_name")
		val video = intent?.getBooleanExtra("video", false) ?: false
		val sessionId = intent?.getStringExtra("call_session_id")
		val autoAccept = intent?.getBooleanExtra("auto_accept_call", false) ?: false

		if (!channel.isNullOrEmpty() && !callerId.isNullOrEmpty()) {
			// Dismiss call notification and stop ringtone
			try {
				val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
				nm.cancel(CallActionReceiver.NOTIF_ID)
			} catch (_: Throwable) {}
			try {
				CallForegroundService.stop(this)
			} catch (_: Throwable) {}



			val callMap = mapOf<String, Any>(
				"channel" to channel,
				"callerId" to callerId,
				"callerName" to (callerName ?: callerId),
				"video" to video,
				"sessionId" to (sessionId ?: ""),
				"autoAccept" to autoAccept
			)
			pendingCallData = callMap

			// Send to Flutter
			navChannel?.invokeMethod("openCall", callMap)

			intent?.removeExtra("call_channel")
			intent?.removeExtra("caller_id")
			intent?.removeExtra("caller_name")
			intent?.removeExtra("video")
			intent?.removeExtra("call_session_id")
			intent?.removeExtra("auto_accept_call")
		}
	}

	private fun clearBadge() {
		try {
			val prefs: SharedPreferences = getSharedPreferences("app_badge", Context.MODE_PRIVATE)
			prefs.edit(commit = true) { putInt("unread", 0) }
			val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
			nm.cancelAll()
		} catch (_: Throwable) {}
	}
}
