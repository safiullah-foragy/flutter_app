package com.example.myapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Automatically starts the background MessageWatcherService when the phone boots up
 * or the app is updated, so incoming calls and messages always arrive even without opening the app.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        Log.d("BootReceiver", "Received action: $action, starting MessageWatcherService...")
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
        ) {
            try {
                MessageWatcherService.start(context)
            } catch (e: Throwable) {
                Log.e("BootReceiver", "Error starting MessageWatcherService", e)
            }
        }
    }
}
