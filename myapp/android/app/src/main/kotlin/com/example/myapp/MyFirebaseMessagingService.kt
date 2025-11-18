package com.example.myapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.media.AudioAttributes
import android.media.RingtoneManager
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.example.myapp.R

class MyFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        val isCallInvite = data["type"] == "call_invite" || data.containsKey("call_channel")
        if (isCallInvite) {
            showIncomingCallFullScreen(data)
            return
        }

        val title = message.notification?.title ?: data["title"] ?: "New message"
        val body = message.notification?.body ?: data["body"] ?: "Open to view"
        val conversationId = data["conversationId"]
        val otherName = data["otherUserName"] ?: data["senderName"] ?: "Contact"

        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            if (conversationId != null) {
                putExtra("conv", conversationId)
            }
        }

        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val channelId = "messages"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Messages",
                NotificationManager.IMPORTANCE_HIGH
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                channel.setAllowBubbles(true)
            }
            nm.createNotificationChannel(channel)
        }

        val person = Person.Builder().setName(otherName).build()

        // Increment badge count
        val prefs = getSharedPreferences("app_badge", Context.MODE_PRIVATE)
        val newCount = (prefs.getInt("unread", 0) + 1).coerceAtMost(999)
        prefs.edit().putInt("unread", newCount).apply()

        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .addPerson(person)
            .setNumber(newCount)
            .setBadgeIconType(NotificationCompat.BADGE_ICON_SMALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setDefaults(android.app.Notification.DEFAULT_ALL)
        if (conversationId != null) {
            builder.setShortcutId(conversationId)
        }

        // Add bubble metadata for Android 10+ (Q), shows on 11+ with user permission
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val bubbleIntent = Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                if (conversationId != null) {
                    putExtra("conv", conversationId)
                }
            }
            val bubblePendingIntent = PendingIntent.getActivity(
                this,
                1,
                bubbleIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                else PendingIntent.FLAG_UPDATE_CURRENT
            )
            val icon = IconCompat.createWithResource(this, R.mipmap.ic_launcher)
            val bubble = NotificationCompat.BubbleMetadata.Builder(bubblePendingIntent, icon)
                .setAutoExpandBubble(true)
                .setSuppressNotification(false)
                .build()
            builder.setBubbleMetadata(bubble)
        }

        val notification = builder.build()

        // Start custom message sound via foreground service so it plays on lock screen/closed app
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val silent = prefs.getBoolean("flutter.ringtone_message_silent", false)
            if (!silent) {
                val assetPath = prefs.getString("flutter.ringtone_message", "Assets/mp3 file/Iphone-Notification.mp3")
                MessageSoundService.start(this, assetPath, 6000)
            }
        } catch (_: Throwable) {}

        nm.notify(System.currentTimeMillis().toInt(), notification)
    }

    override fun onNewToken(token: String) {
        // No-op: Flutter layer handles token upload.
    }

    private fun showIncomingCallFullScreen(data: Map<String, String>) {
        val channel = data["call_channel"] ?: return
        val callerId = data["caller_id"] ?: ""
        val callerName = data["caller_name"] ?: callerId
        val isVideo = (data["video"] == "1" || data["video"] == "true")

        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("call_channel", channel)
            putExtra("caller_id", callerId)
            putExtra("callee_id", data["callee_id"]) 
            putExtra("caller_name", callerName)
            putExtra("video", isVideo)
            putExtra("call_session_id", data["call_session_id"]) 
        }
        val fullScreenPi = PendingIntent.getActivity(
            this,
            100,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "incoming_call"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(channelId, "Incoming Calls", NotificationManager.IMPORTANCE_HIGH)
                val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ch.setSound(uri, AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build())
                ch.enableVibration(true)
                nm.createNotificationChannel(ch)
            }
        }

        val builder = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(callerName)
            .setContentText(if (isVideo) "Incoming video call" else "Incoming audio call")
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setFullScreenIntent(fullScreenPi, true)

        // Action buttons: Accept / Decline
        val acceptIntent = Intent(this, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_ACCEPT
            putExtra("call_session_id", data["call_session_id"])
            putExtra("call_channel", channel)
            putExtra("caller_id", callerId)
            putExtra("callee_id", data["callee_id"]) 
            putExtra("video", isVideo)
        }
        val declineIntent = Intent(this, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_DECLINE
            putExtra("call_session_id", data["call_session_id"])
            putExtra("call_channel", channel)
            putExtra("caller_id", callerId)
            putExtra("callee_id", data["callee_id"]) 
            putExtra("video", isVideo)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
        val acceptPi = PendingIntent.getBroadcast(this, 201, acceptIntent, flags)
        val declinePi = PendingIntent.getBroadcast(this, 202, declineIntent, flags)
        builder.addAction(R.mipmap.ic_launcher, "Accept", acceptPi)
        builder.addAction(R.mipmap.ic_launcher, "Reject", declinePi)

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            builder.setSound(uri)
            builder.setDefaults(Notification.DEFAULT_VIBRATE)
        }

        // Post with stable ID so it can be updated/canceled later
        // Start ringtone foreground service for continuous ringing (if not silent)
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val silent = prefs.getBoolean("flutter.ringtone_call_silent", false)
            if (!silent) {
                val assetPath = prefs.getString("flutter.ringtone_call", "Assets/mp3 file/lovely-Alarm.mp3")
                CallForegroundService.start(this, if (isVideo) "Incoming video call" else "Incoming audio call", callerName, isVideo, true, assetPath)
            }
        } catch (_: Throwable) {}

        nm.notify(999001, builder.build())
    }
}
 
