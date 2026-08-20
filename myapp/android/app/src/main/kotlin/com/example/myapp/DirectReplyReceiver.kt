package com.example.myapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions

/**
 * Handles inline direct replies from the notification shade
 * and sends the message directly to Firestore without requiring the app to open.
 */
class DirectReplyReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val remoteInput: Bundle? = RemoteInput.getResultsFromIntent(intent)
        val replyText = remoteInput?.getCharSequence(KEY_TEXT_REPLY)?.toString()?.trim()

        val conversationId = intent.getStringExtra(EXTRA_CONVERSATION_ID)
        val notificationId = intent.getIntExtra(EXTRA_NOTIFICATION_ID, 0)
        val title = intent.getStringExtra(EXTRA_TITLE) ?: "Messages"

        if (replyText.isNullOrEmpty() || conversationId.isNullOrEmpty()) {
            return
        }

        val pendingResult = goAsync()

        try {
            FirebaseApp.initializeApp(context)
        } catch (_: Throwable) {}

        // Resolve current user UID
        var uid: String? = null
        try {
            uid = FirebaseAuth.getInstance().currentUser?.uid
        } catch (_: Throwable) {}

        if (uid.isNullOrEmpty()) {
            try {
                val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                uid = prefs.getString("flutter.last_topic_uid", null)
            } catch (_: Throwable) {}
        }

        if (uid.isNullOrEmpty()) {
            Log.e("DirectReplyReceiver", "No logged in user found to send reply.")
            pendingResult.finish()
            return
        }

        val finalUid = uid
        val db = FirebaseFirestore.getInstance()
        val now = System.currentTimeMillis()

        val messageData = hashMapOf<String, Any>(
            "sender_id" to finalUid,
            "text" to replyText,
            "timestamp" to now,
            "file_url" to "",
            "file_type" to "",
            "reactions" to hashMapOf<String, Any>(),
            "edited" to false
        )

        // 1. Add message to subcollection
        db.collection("conversations")
            .document(conversationId)
            .collection("messages")
            .add(messageData)
            .addOnSuccessListener {
                // 2. Update conversation header
                val convUpdates = hashMapOf<String, Any>(
                    "last_message" to replyText,
                    "last_updated" to now,
                    "last_read" to hashMapOf(finalUid to now)
                )
                db.collection("conversations")
                    .document(conversationId)
                    .set(convUpdates, SetOptions.merge())

                // 3. Update notification to confirm reply sent
                updateNotificationConfirmed(context, notificationId, conversationId, title, replyText)
                pendingResult.finish()
            }
            .addOnFailureListener { e ->
                Log.e("DirectReplyReceiver", "Failed to send direct reply", e)
                pendingResult.finish()
            }
    }

    private fun updateNotificationConfirmed(
        context: Context,
        notificationId: Int,
        conversationId: String,
        title: String,
        replyText: String
    ) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "messages"

        val openIntent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("conv", conversationId)
        }
        val pi = PendingIntent.getActivity(
            context,
            notificationId,
            openIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val updated = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText("You: $replyText")
            .setContentIntent(pi)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        nm.notify(notificationId, updated)
    }

    companion object {
        const val KEY_TEXT_REPLY = "key_text_reply"
        const val EXTRA_CONVERSATION_ID = "extra_conversation_id"
        const val EXTRA_NOTIFICATION_ID = "extra_notification_id"
        const val EXTRA_TITLE = "extra_title"
    }
}
