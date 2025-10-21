package com.example.myapp

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private var navChannel: MethodChannel? = null

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)
		navChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.myapp/navigation")
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
}

