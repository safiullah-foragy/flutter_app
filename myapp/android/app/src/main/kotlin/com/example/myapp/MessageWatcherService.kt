package com.example.myapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.DocumentChange
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.Query
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

import android.content.pm.ServiceInfo
import androidx.core.app.ServiceCompat

/**
 * Foreground service that keeps a lightweight Firestore listener running
 * while the app is backgrounded, generating instant local notifications
 * with round sender avatars and inline replies.
 */
class MessageWatcherService : Service() {
    private val watcherChannelId = "message_watcher"
    private val messagesChannelId = "messages_popup_v2"
    private var reg: ListenerRegistration? = null
    private var callReg: ListenerRegistration? = null
    private var baseline: MutableMap<String, Long> = mutableMapOf()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        startInForeground()
        try { FirebaseApp.initializeApp(this) } catch (_: Throwable) {}
        attachListener()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startInForeground()
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        try { reg?.remove() } catch (_: Throwable) {}
        try { callReg?.remove() } catch (_: Throwable) {}
        reg = null
        callReg = null
    }

    private fun startInForeground() {
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val existing = nm.getNotificationChannel(watcherChannelId)
                if (existing == null) {
                    val ch = NotificationChannel(watcherChannelId, "Background Sync", NotificationManager.IMPORTANCE_MIN)
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
            val notif: Notification = NotificationCompat.Builder(this, watcherChannelId)
                .setContentTitle("Connectify Background Sync")
                .setContentText("Listening for messages")
                .setSmallIcon(R.mipmap.ic_launcher)
                .setOngoing(true)
                .setContentIntent(pi)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .build()

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(
                    this,
                    1001,
                    notif,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(1001, notif)
            }
        } catch (_: Throwable) {
            try {
                val notif = NotificationCompat.Builder(this, watcherChannelId)
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .build()
                startForeground(1001, notif)
            } catch (_: Throwable) {}
        }
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

        db.collection("conversations")
            .whereArrayContains("participants", uid)
            .get()
            .addOnSuccessListener { snap ->
                for (doc in snap.documents) {
                    val lu = (doc.getLong("last_updated") ?: 0L)
                    baseline[doc.id] = lu
                }
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
                                    baseline[d.id] = lastUpdated
                                    notifyLatestMessage(db, d.id, uid)
                                }
                            }
                        }
                    }
            }
            .addOnFailureListener { _ ->
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

        // Attach listener for incoming call sessions
        callReg = db.collection("call_sessions")
            .whereEqualTo("callee_id", uid)
            .whereEqualTo("status", "ringing")
            .addSnapshotListener { snap, err ->
                if (err != null || snap == null) return@addSnapshotListener
                for (dc in snap.documentChanges) {
                    if (dc.type == DocumentChange.Type.ADDED || dc.type == DocumentChange.Type.MODIFIED) {
                        val d = dc.document
                        val status = d.getString("status") ?: ""
                        if (status == "ringing") {
                            notifyIncomingCall(db, d.id, d.data ?: emptyMap())
                        }
                    } else if (dc.type == DocumentChange.Type.REMOVED) {
                        try {
                            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            nm.cancel(CallActionReceiver.NOTIF_ID)
                        } catch (_: Throwable) {}
                    }
                }
            }
    }

    private fun notifyIncomingCall(db: FirebaseFirestore, sessionId: String, data: Map<String, Any>) {
        val channel = data["channel"] as? String ?: return
        val callerId = data["caller_id"] as? String ?: return
        val isVideo = (data["video"] as? Boolean) ?: false
        val calleeId = data["callee_id"] as? String ?: ""

        db.collection("users").document(callerId).get()
            .addOnSuccessListener { udoc ->
                val callerName = (udoc.getString("name") ?: udoc.getString("displayName") ?: callerId)
                val photoUrl = udoc.getString("photo_url") ?: udoc.getString("profile_image") ?: udoc.getString("image") ?: udoc.getString("avatar")
                showCallNotification(sessionId, channel, callerId, callerName, photoUrl, isVideo, calleeId)
            }
            .addOnFailureListener {
                showCallNotification(sessionId, channel, callerId, callerId, null, isVideo, calleeId)
            }
    }

    private fun showCallNotification(
        sessionId: String,
        channel: String,
        callerId: String,
        callerName: String,
        photoUrl: String?,
        isVideo: Boolean,
        calleeId: String
    ) {
        val channelId = "calls"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(channelId, "Calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Incoming call notifications"
                    setSound(
                        RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                        AudioAttributes.Builder()
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .build()
                    )
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 1000, 1000, 1000, 1000)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setBypassDnd(true)
                }
                nm.createNotificationChannel(ch)
            }
        }

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

        val declineIntent = Intent(this, CallActionReceiver::class.java).apply {
            action = CallActionReceiver.ACTION_DECLINE
            putExtra("call_session_id", sessionId)
            putExtra("call_channel", channel)
            putExtra("caller_id", callerId)
            putExtra("caller_name", callerName)
            putExtra("callee_id", calleeId)
            putExtra("video", isVideo)
        }
        val declinePi = PendingIntent.getBroadcast(
            this, 202, declineIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            else PendingIntent.FLAG_UPDATE_CURRENT
        )

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

    private fun notifyLatestMessage(db: FirebaseFirestore, conversationId: String, me: String) {
        db.collection("conversations").document(conversationId).get()
            .addOnSuccessListener { doc ->
                val parts = (doc.get("participants") as? List<*>)?.mapNotNull { it as? String } ?: emptyList()
                val otherId = parts.firstOrNull { it != me } ?: ""
                db.collection("conversations").document(conversationId)
                    .collection("messages")
                    .orderBy("timestamp", Query.Direction.DESCENDING)
                    .limit(1)
                    .get()
                    .addOnSuccessListener { snap ->
                        val msgDoc = snap.documents.firstOrNull()
                        val data = msgDoc?.data ?: emptyMap<String, Any>()
                        val senderId = (data["sender_id"] ?: data["user_id"]) as? String ?: ""
                        if (senderId == me) return@addOnSuccessListener

                        val text = (data["text"] as? String)?.takeIf { it.isNotBlank() }

                        // Filter out call-related messages from message notifications
                        if (text != null && (
                            text.contains("Started an audio call", ignoreCase = true) ||
                            text.contains("Started a video call", ignoreCase = true) ||
                            text.contains("Incoming audio call", ignoreCase = true) ||
                            text.contains("Incoming video call", ignoreCase = true) ||
                            text.contains("Missed audio call", ignoreCase = true) ||
                            text.contains("Missed video call", ignoreCase = true) ||
                            text.contains("Call ended", ignoreCase = true) ||
                            text.contains("Call declined", ignoreCase = true)
                        )) {
                            return@addOnSuccessListener
                        }

                        val fileType = data["file_type"] as? String ?: ""
                        val body = when {
                            text != null -> text
                            fileType == "image" -> "📷 Sent an image"
                            fileType == "video" -> "🎥 Sent a video"
                            fileType == "audio" -> "🎤 Sent a voice message"
                            fileType == "file" -> "📄 Sent a document"
                            else -> "New message"
                        }
                        if (otherId.isNotEmpty()) {
                            db.collection("users").document(otherId).get()
                                .addOnSuccessListener { udoc ->
                                    val otherName = (udoc.get("name") as? String) ?: otherId
                                    val photoUrl = (udoc.get("photo_url")
                                        ?: udoc.get("profile_image")
                                        ?: udoc.get("image")
                                        ?: udoc.get("avatar")
                                        ?: udoc.get("photoURL")) as? String
                                    postSystemNotification(conversationId, otherName, body, photoUrl)
                                }
                                .addOnFailureListener { _ -> postSystemNotification(conversationId, otherId, body, null) }
                        } else {
                            postSystemNotification(conversationId, "New message", body, null)
                        }
                    }
                    .addOnFailureListener { _ ->
                        postSystemNotification(conversationId, "New message", "Open to view", null)
                    }
            }
    }

    private fun postSystemNotification(conversationId: String, title: String, body: String, photoUrl: String?) {
        thread {
            val circularBitmap = downloadCircularBitmap(photoUrl)

            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val ch = nm.getNotificationChannel(messagesChannelId)
                if (ch == null) {
                    val channel = NotificationChannel(messagesChannelId, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                        description = "Shows popup banner for incoming messages"
                        enableVibration(true)
                        vibrationPattern = longArrayOf(0, 250, 200, 250)
                        lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                        setShowBadge(true)
                        setBypassDnd(true)
                    }
                    nm.createNotificationChannel(channel)
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

            // Inline Direct Reply Action
            val remoteInput = androidx.core.app.RemoteInput.Builder(DirectReplyReceiver.KEY_TEXT_REPLY)
                .setLabel("Reply...")
                .build()

            val replyIntent = Intent(this, DirectReplyReceiver::class.java).apply {
                putExtra(DirectReplyReceiver.EXTRA_CONVERSATION_ID, conversationId)
                putExtra(DirectReplyReceiver.EXTRA_NOTIFICATION_ID, conversationId.hashCode())
                putExtra(DirectReplyReceiver.EXTRA_TITLE, title)
            }

            val replyPendingIntent = PendingIntent.getBroadcast(
                this,
                conversationId.hashCode() + 10,
                replyIntent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                else
                    PendingIntent.FLAG_UPDATE_CURRENT
            )

            val replyAction = NotificationCompat.Action.Builder(
                R.mipmap.ic_launcher,
                "Reply",
                replyPendingIntent
            )
                .addRemoteInput(remoteInput)
                .setAllowGeneratedReplies(true)
                .build()

            val personBuilder = Person.Builder().setName(title)
            if (circularBitmap != null) {
                personBuilder.setIcon(IconCompat.createWithBitmap(circularBitmap))
            }
            val person = personBuilder.build()

            val builder = NotificationCompat.Builder(this, messagesChannelId)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(body)
                .setAutoCancel(true)
                .setContentIntent(pi)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .addPerson(person)
                .setDefaults(NotificationCompat.DEFAULT_ALL)
                .setVibrate(longArrayOf(0, 250, 200, 250))
                .addAction(replyAction)

            if (circularBitmap != null) {
                builder.setLargeIcon(circularBitmap)
            }

            nm.notify(conversationId.hashCode(), builder.build())
        }
    }

    private fun downloadCircularBitmap(urlStr: String?): Bitmap? {
        if (urlStr.isNullOrEmpty()) return null
        return try {
            val url = URL(urlStr)
            val conn = url.openConnection() as HttpURLConnection
            conn.doInput = true
            conn.connectTimeout = 4000
            conn.readTimeout = 4000
            conn.connect()
            val stream = conn.inputStream
            val original = BitmapFactory.decodeStream(stream)
            stream.close()
            conn.disconnect()
            if (original != null) getCircularBitmap(original) else null
        } catch (_: Throwable) {
            null
        }
    }

    private fun getCircularBitmap(bitmap: Bitmap): Bitmap {
        val size = Math.min(bitmap.width, bitmap.height)
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint().apply {
            isAntiAlias = true
            isFilterBitmap = true
            isDither = true
            val x = (bitmap.width - size) / 2
            val y = (bitmap.height - size) / 2
            val cropped = Bitmap.createBitmap(bitmap, x, y, size, size)
            shader = BitmapShader(cropped, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        }
        val radius = size / 2f
        canvas.drawCircle(radius, radius, radius, paint)
        return output
    }

    companion object {
        fun start(ctx: Context) {
            try {
                val i = Intent(ctx, MessageWatcherService::class.java)
                ContextCompat.startForegroundService(ctx, i)
            } catch (_: Throwable) {}
        }
        fun stop(ctx: Context) {
            try {
                val i = Intent(ctx, MessageWatcherService::class.java)
                ctx.stopService(i)
            } catch (_: Throwable) {}
        }
    }
}
