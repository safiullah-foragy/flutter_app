package com.example.myapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentChange
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query

/**
 * Foreground service that keeps a lightweight Firestore listener running
 * while the app is backgrounded, so we can generate instant local
 * notifications for new messages without requiring Cloud Functions.
 */
class MessageWatcherService : Service() {
    // Use a separate, low-importance channel for the foreground service itself
    private val channelId = "message_watcher"
    private var reg: ListenerRegistration? = null
    private var baseline: MutableMap<String, Long> = mutableMapOf()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        try { FirebaseApp.initializeApp(this) } catch (_: Throwable) {}
        startInForeground()
        attachListener()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Ensure running as foreground
        startInForeground()
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        try { reg?.remove() } catch (_: Throwable) {}
        reg = null
    }

    private fun startInForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val existing = nm.getNotificationChannel(channelId)
            if (existing == null) {
                val ch = NotificationChannel(channelId, "Background", NotificationManager.IMPORTANCE_MIN)
                ch.setShowBadge(false)
                ch.setSound(null, null)
                nm.createNotificationChannel(ch)
            }
        }
        val openIntent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(
            this, 0, openIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("myapp")
            .setContentText("")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .build()
        startForeground(1001, notif)
    }

    private fun attachListener() {
        val auth = FirebaseAuth.getInstance()
        val user = auth.currentUser
        if (user == null) {
            stopSelf()
            return
        }
        val uid = user.uid
        val db = FirebaseFirestore.getInstance()
        // First, prime baseline with current state to avoid flooding
        db.collection("conversations")
            .whereArrayContains("participants", uid)
            .get()
            .addOnSuccessListener { snap ->
                for (doc in snap.documents) {
                    val lu = (doc.getLong("last_updated") ?: 0L)
                    baseline[doc.id] = lu
                }
                // Now start listening to changes
                reg = db.collection("conversations")
                    .whereArrayContains("participants", uid)
                    .addSnapshotListener { value, error ->
                        if (error != null || value == null) return@addSnapshotListener
                        for (dc in value.documentChanges) {
                            if (dc.type == DocumentChange.Type.MODIFIED || dc.type == DocumentChange.Type.ADDED) {
                                val d = dc.document
                                val lastUpdated = d.getLong("last_updated") ?: 0L
                                val lastReadMap = d.get("last_read") as? Map<*, *> ?: emptyMap<String, Any>()
                                val lastRead = (lastReadMap[uid] as? Number)?.toLong() ?: 0L
                                val base = baseline[d.id] ?: 0L
                                val isUnread = lastUpdated > lastRead && lastUpdated > base
                                if (isUnread) {
                                    // Update baseline to avoid duplicate
                                    baseline[d.id] = lastUpdated
                                    notifyLatestMessage(db, d.id, uid)
                                }
                            }
                        }
                    }
            }
            .addOnFailureListener { _ ->
                // If we couldn't read baseline, still attach listener; will likely notify once for existing
                reg = db.collection("conversations")
                    .whereArrayContains("participants", uid)
                    .addSnapshotListener { value, error ->
                        if (error != null || value == null) return@addSnapshotListener
                        for (dc in value.documentChanges) {
                            if (dc.type != DocumentChange.Type.REMOVED) {
                                val d = dc.document
                                val lastUpdated = d.getLong("last_updated") ?: 0L
                                val lastReadMap = d.get("last_read") as? Map<*, *> ?: emptyMap<String, Any>()
                                val lastRead = (lastReadMap[uid] as? Number)?.toLong() ?: 0L
                                if (lastUpdated > lastRead) notifyLatestMessage(db, d.id, uid)
                            }
                        }
                    }
            }
    }

    private fun notifyLatestMessage(db: FirebaseFirestore, conversationId: String, me: String) {
        // Fetch participants to determine other user id
        db.collection("conversations").document(conversationId).get()
            .addOnSuccessListener { doc ->
                val parts = (doc.get("participants") as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
                val otherId = parts.firstOrNull { it != me } ?: ""
                // Fetch latest message text
                db.collection("conversations").document(conversationId)
                    .collection("messages")
                    .orderBy("timestamp", Query.Direction.DESCENDING)
                    .limit(1)
                    .get()
                    .addOnSuccessListener { snap ->
                        val msgDoc = snap.documents.firstOrNull()
                        val data = msgDoc?.data ?: emptyMap<String, Any>()
                        val text = (data["text"] as? String)?.takeIf { it.isNotBlank() }
                        val fileType = data["file_type"] as? String ?: ""
                        val body = when {
                            text != null -> text
                            fileType == "image" -> "[Image]"
                            fileType == "video" -> "[Video]"
                            else -> "New message"
                        }
                        // Fetch other user's name for title
                        if (otherId.isNotEmpty()) {
                            db.collection("users").document(otherId).get()
                                .addOnSuccessListener { udoc ->
                                    val otherName = (udoc.get("name") as? String) ?: otherId
                                    postSystemNotification(conversationId, otherName, body)
                                }
                                .addOnFailureListener { _ -> postSystemNotification(conversationId, otherId, body) }
                        } else {
                            postSystemNotification(conversationId, "New message", body)
                        }
                    }
                    .addOnFailureListener { _ ->
                        postSystemNotification(conversationId, "New message", "Open to view")
                    }
            }
    }

    private fun postSystemNotification(conversationId: String, title: String, body: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = nm.getNotificationChannel(channelId)
            if (ch == null) {
                nm.createNotificationChannel(
                    NotificationChannel(channelId, "Messages", NotificationManager.IMPORTANCE_HIGH)
                )
            }
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("conv", conversationId)
        }
        val pi = PendingIntent.getActivity(
            this, conversationId.hashCode(), intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()
        // Use stable ID per conversation to collapse updates
        nm.notify(conversationId.hashCode(), notification)
    }

    companion object {
        fun start(ctx: Context) {
            val i = Intent(ctx, MessageWatcherService::class.java)
            ContextCompat.startForegroundService(ctx, i)
        }
        fun stop(ctx: Context) {
            val i = Intent(ctx, MessageWatcherService::class.java)
            ctx.stopService(i)
        }
    }
}
