package com.example.myapp

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.example.myapp.R

class MyFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
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

        nm.notify(System.currentTimeMillis().toInt(), notification)
    }

    override fun onNewToken(token: String) {
        // No-op: Flutter layer handles token upload.
    }
}
 
