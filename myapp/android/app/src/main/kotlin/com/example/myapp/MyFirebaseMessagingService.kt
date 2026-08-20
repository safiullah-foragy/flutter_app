package com.example.myapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.os.Build
import android.media.AudioAttributes
import android.media.RingtoneManager
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.graphics.drawable.IconCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.example.myapp.R
import com.google.firebase.FirebaseApp
import com.google.firebase.firestore.FirebaseFirestore
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class MyFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val isCallInvite = data["type"] == "call_invite" || data.containsKey("call_channel")
        if (isCallInvite) {
            showIncomingCall(data)
            return
        }

        val title = message.notification?.title ?: data["title"] ?: data["senderName"] ?: "New message"
        val body = message.notification?.body ?: data["body"] ?: "You have a new message"

        // Filter out call messages from standard notification banners
        if (body.contains("Started an audio call", ignoreCase = true) ||
            body.contains("Started a video call", ignoreCase = true) ||
            body.contains("Incoming audio call", ignoreCase = true) ||
            body.contains("Incoming video call", ignoreCase = true) ||
            body.contains("Missed audio call", ignoreCase = true) ||
            body.contains("Missed video call", ignoreCase = true) ||
            body.contains("Call ended", ignoreCase = true) ||
            body.contains("Call declined", ignoreCase = true)) {
            return
        }

        val conversationId = data["conversationId"]
        val otherName = data["otherUserName"] ?: data["senderName"] ?: "Contact"
        val photoUrl = data["senderImage"] ?: data["photo_url"] ?: data["image"] ?: data["avatar"]

        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (conversationId != null) putExtra("conv", conversationId)
        }

        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val channelId = "messages_popup_v2"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(channelId) == null) {
                val channel = NotificationChannel(channelId, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Message popup notifications"
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 250, 200, 250)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setShowBadge(true)
                    setBypassDnd(true)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) channel.setAllowBubbles(true)
                nm.createNotificationChannel(channel)
            }
        }

        val prefs = getSharedPreferences("app_badge", Context.MODE_PRIVATE)
        val newCount = (prefs.getInt("unread", 0) + 1).coerceAtMost(999)
        prefs.edit().putInt("unread", newCount).apply()

        val remoteInput = RemoteInput.Builder(DirectReplyReceiver.KEY_TEXT_REPLY).setLabel("Reply...").build()
        val replyIntent = Intent(this, DirectReplyReceiver::class.java).apply {
            if (conversationId != null) {
                putExtra(DirectReplyReceiver.EXTRA_CONVERSATION_ID, conversationId)
                putExtra(DirectReplyReceiver.EXTRA_NOTIFICATION_ID, conversationId.hashCode())
            }
            putExtra(DirectReplyReceiver.EXTRA_TITLE, title)
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            this, (conversationId?.hashCode() ?: 100) + 10, replyIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )
        val replyAction = NotificationCompat.Action.Builder(R.mipmap.ic_launcher, "Reply", replyPendingIntent)
            .addRemoteInput(remoteInput).setAllowGeneratedReplies(true).build()

        thread {
            val circularBitmap = downloadCircularBitmap(photoUrl)
            val personBuilder = Person.Builder().setName(otherName)
            if (circularBitmap != null) personBuilder.setIcon(IconCompat.createWithBitmap(circularBitmap))
            val person = personBuilder.build()

            val builder = NotificationCompat.Builder(this, channelId)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .addPerson(person)
                .addAction(replyAction)
                .setNumber(newCount)
                .setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setDefaults(android.app.Notification.DEFAULT_ALL)
                .setVibrate(longArrayOf(0, 250, 200, 250))
            if (circularBitmap != null) builder.setLargeIcon(circularBitmap)
            if (conversationId != null) builder.setShortcutId(conversationId)

            nm.notify(System.currentTimeMillis().toInt(), builder.build())
        }
    }

    override fun onNewToken(token: String) {
        // Flutter layer handles token upload.
    }

    /**
     * Show the incoming call UI.
     * - If we can start activities (app in foreground/background but alive): launch IncomingCallActivity directly.
     * - Always also post a high-priority call notification as fallback for completely killed state.
     */
    private fun showIncomingCall(data: Map<String, String>) {
        val channel = data["call_channel"] ?: return
        val callerId = data["caller_id"] ?: ""
        val callerName = data["caller_name"] ?: callerId
        val calleeId = data["callee_id"] ?: ""
        val isVideo = (data["video"] == "1" || data["video"] == "true")
        val sessionId = data["call_session_id"] ?: ""
        val photoUrl = data["photo_url"] ?: data["caller_image"] ?: ""

        if (sessionId.isNotEmpty()) {
            try { FirebaseApp.initializeApp(this) } catch (_: Throwable) {}
            val docRef = FirebaseFirestore.getInstance().collection("call_sessions").document(sessionId)
            docRef.get().addOnSuccessListener { doc ->
                if (!doc.exists()) return@addOnSuccessListener
                val status = doc.getString("status") ?: return@addOnSuccessListener
                if (status != "ringing") return@addOnSuccessListener
                val ts = doc.getLong("timestamp") ?: doc.getLong("created_at") ?: 0L
                val age = System.currentTimeMillis() - ts
                if (ts > 0 && age > 55_000) return@addOnSuccessListener // stale call

                postCallNotification(channel, callerId, callerName, calleeId, isVideo, sessionId, photoUrl)

                // Real-time listener to dismiss notification immediately if caller cancels
                docRef.addSnapshotListener { snapshot, _ ->
                    if (snapshot == null || !snapshot.exists() || snapshot.getString("status") != "ringing") {
                        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        nm.cancel(CallActionReceiver.NOTIF_ID)
                    }
                }
            }.addOnFailureListener {
                postCallNotification(channel, callerId, callerName, calleeId, isVideo, sessionId, photoUrl)
            }
        } else {
            postCallNotification(channel, callerId, callerName, calleeId, isVideo, sessionId, photoUrl)
        }
    }

    private fun postCallNotification(channel: String, callerId: String, callerName: String,
                                      calleeId: String, isVideo: Boolean, sessionId: String, photoUrl: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "incoming_call_popup_v2"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(channelId, "Incoming Calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build())
                    enableVibration(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setBypassDnd(true)
                }
                nm.createNotificationChannel(ch)
            }
        }

        // Accept action — broadcast to CallActionReceiver which marks accepted and launches MainActivity
        val acceptIntent = Intent(this, MainActivity::class.java).apply {
            action = "com.example.myapp.ACTION_CALL_ACCEPT"
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("call_session_id", sessionId)
            putExtra("call_channel", channel)
            putExtra("caller_id", callerId)
            putExtra("caller_name", callerName)
            putExtra("callee_id", calleeId)
            putExtra("video", isVideo)
            putExtra("auto_accept_call", true)
        }
        val acceptPi = PendingIntent.getActivity(
            this, (sessionId.hashCode() and 0x7FFFFFFF), acceptIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )

        // Decline action — broadcast to CallActionReceiver
        val declineIntent = Intent(this, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_DECLINE
            putExtra("call_session_id", sessionId)
            putExtra("call_channel", channel)
            putExtra("caller_id", callerId)
            putExtra("caller_name", callerName)
            putExtra("callee_id", calleeId)
            putExtra("video", isVideo)
        }
        val declinePi = PendingIntent.getBroadcast(this, 202, declineIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)

        thread {
            val circularBitmap = downloadCircularBitmap(photoUrl)
            val personBuilder = Person.Builder().setName(callerName)
            if (circularBitmap != null) personBuilder.setIcon(IconCompat.createWithBitmap(circularBitmap))
            val person = personBuilder.build()

            val builder = NotificationCompat.Builder(this, channelId)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(callerName)
                .setContentText(if (isVideo) "Incoming video call" else "Incoming audio call")
                .setAutoCancel(true)
                .setContentIntent(acceptPi)
                .setFullScreenIntent(acceptPi, true)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .addPerson(person)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true)
                .setColor(android.graphics.Color.parseColor("#00E676"))
                .setColorized(true)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "🔴 Decline",
                    declinePi
                )
                .addAction(
                    android.R.drawable.ic_menu_call,
                    "🟢 Receive",
                    acceptPi
                )

            if (circularBitmap != null) builder.setLargeIcon(circularBitmap)

            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                builder.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))
                builder.setDefaults(Notification.DEFAULT_VIBRATE)
            }

            nm.notify(CallActionReceiver.NOTIF_ID, builder.build())
        }
    }

    private fun downloadCircularBitmap(urlStr: String?): Bitmap? {
        if (urlStr.isNullOrEmpty()) return null
        return try {
            val conn = URL(urlStr).openConnection() as HttpURLConnection
            conn.doInput = true; conn.connectTimeout = 4000; conn.readTimeout = 4000; conn.connect()
            val original = BitmapFactory.decodeStream(conn.inputStream)
            conn.disconnect()
            if (original != null) getCircularBitmap(original) else null
        } catch (_: Throwable) { null }
    }

    private fun getCircularBitmap(bitmap: Bitmap): Bitmap {
        val size = minOf(bitmap.width, bitmap.height)
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            val x = (bitmap.width - size) / 2; val y = (bitmap.height - size) / 2
            shader = BitmapShader(Bitmap.createBitmap(bitmap, x, y, size, size), Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }
        Canvas(output).drawCircle(size / 2f, size / 2f, size / 2f, paint)
        return output
    }
}
