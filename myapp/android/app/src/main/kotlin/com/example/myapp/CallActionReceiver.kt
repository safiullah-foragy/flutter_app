package com.example.myapp

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.app.NotificationManager
import android.os.Build
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.firestore.FirebaseFirestore

class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val sessionId = intent.getStringExtra("call_session_id") ?: return
        val channel = intent.getStringExtra("call_channel") ?: ""
        val callerId = intent.getStringExtra("caller_id") ?: ""
        val isVideo = intent.getBooleanExtra("video", false)
        val calleeId = intent.getStringExtra("callee_id")

        try { FirebaseApp.initializeApp(context) } catch (_: Throwable) {}
        val db = FirebaseFirestore.getInstance()

        when (action) {
            ACTION_ACCEPT -> {
                // Update session to accepted and open the app's call UI
                db.collection("call_sessions").document(sessionId)
                    .update(mapOf("status" to "accepted", "accepted_at" to System.currentTimeMillis()))
                    .addOnCompleteListener {
                        // Launch main activity to open Call UI
                        val open = Intent(context, MainActivity::class.java).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            putExtra("call_channel", channel)
                            putExtra("caller_id", callerId)
                            putExtra("video", isVideo)
                        }
                        ContextCompat.startActivity(context, open, null)
                        stopRinging(context)
                    }
            }
            ACTION_DECLINE -> {
                val updates = mutableMapOf<String, Any>("status" to "rejected", "ended_at" to System.currentTimeMillis())
                if (!calleeId.isNullOrEmpty()) updates["ended_by"] = calleeId
                db.collection("call_sessions").document(sessionId)
                    .update(updates)
                    .addOnCompleteListener { stopRinging(context) }
            }
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
