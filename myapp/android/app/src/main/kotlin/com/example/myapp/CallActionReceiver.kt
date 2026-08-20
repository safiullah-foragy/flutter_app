package com.example.myapp

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions

/**
 * Handles Accept and Decline actions from incoming call heads-up notifications.
 * Also handles cancelling the IncomingCallActivity via broadcast.
 */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val sessionId = intent.getStringExtra("call_session_id") ?: ""
        val channel = intent.getStringExtra("call_channel") ?: ""
        val callerId = intent.getStringExtra("caller_id") ?: ""
        val callerName = intent.getStringExtra("caller_name") ?: callerId
        val isVideo = intent.getBooleanExtra("video", false)
        val calleeId = intent.getStringExtra("callee_id") ?: ""

        val pendingResult = goAsync()

        try { FirebaseApp.initializeApp(context) } catch (_: Throwable) {}
        val db = FirebaseFirestore.getInstance()

        when (action) {
            ACTION_ACCEPT -> {
                stopRinging(context)

                if (sessionId.isNotEmpty()) {
                    db.collection("call_sessions").document(sessionId)
                        .set(hashMapOf<String, Any>(
                            "status" to "accepted",
                            "accepted_at" to System.currentTimeMillis()
                        ), SetOptions.merge())
                }

                // Launch MainActivity with auto-accept to open Flutter call UI
                val open = Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    putExtra("call_channel", channel)
                    putExtra("caller_id", callerId)
                    putExtra("caller_name", callerName)
                    putExtra("video", isVideo)
                    putExtra("call_session_id", sessionId)
                    putExtra("auto_accept_call", true)
                }
                try { context.startActivity(open) } catch (e: Throwable) {
                    Log.e("CallActionReceiver", "Failed to start activity", e)
                }
                pendingResult.finish()
            }
            ACTION_DECLINE -> {
                stopRinging(context)

                if (sessionId.isNotEmpty()) {
                    val updates = hashMapOf<String, Any>(
                        "status" to "rejected",
                        "ended_at" to System.currentTimeMillis()
                    )
                    if (calleeId.isNotEmpty()) updates["ended_by"] = calleeId
                    db.collection("call_sessions").document(sessionId)
                        .set(updates, SetOptions.merge())
                        .addOnCompleteListener { pendingResult.finish() }
                } else {
                    pendingResult.finish()
                }

                // Tell IncomingCallActivity to close (in case it's showing)
                val cancelBroadcast = Intent(IncomingCallActivity.ACTION_CANCEL_INCOMING_CALL)
                cancelBroadcast.setPackage(context.packageName)
                context.sendBroadcast(cancelBroadcast)
            }
            else -> pendingResult.finish()
        }
    }

    private fun stopRinging(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NOTIF_ID)
        } catch (_: Throwable) {}
        try { CallForegroundService.stop(context) } catch (_: Throwable) {}
    }

    companion object {
        const val ACTION_ACCEPT = "com.example.myapp.ACTION_CALL_ACCEPT"
        const val ACTION_DECLINE = "com.example.myapp.ACTION_CALL_DECLINE"
        const val NOTIF_ID = 999001
    }
}
