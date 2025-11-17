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

/**
 * Lightweight foreground service used while an audio/video call is active,
 * so the call keeps running when the app goes to background.
 */
class CallForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Ongoing call"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val video = intent?.getBooleanExtra(EXTRA_VIDEO, false) ?: false
        startForegroundInternal(title, text, video)
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
    }

    private fun startForegroundInternal(title: String, text: String, video: Boolean) {
        val channelId = CHANNEL_ID
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(channelId, "Call", NotificationManager.IMPORTANCE_LOW)
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
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setOnlyAlertOnce(true)
            .build()
        startForeground(NOTIF_ID, notif)
    }

    companion object {
        private const val CHANNEL_ID = "call_foreground"
        private const val NOTIF_ID = 2001
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_VIDEO = "video"

        fun start(ctx: Context, title: String, text: String, video: Boolean) {
            val i = Intent(ctx, CallForegroundService::class.java)
            i.putExtra(EXTRA_TITLE, title)
            i.putExtra(EXTRA_TEXT, text)
            i.putExtra(EXTRA_VIDEO, video)
            ContextCompat.startForegroundService(ctx, i)
        }
        fun stop(ctx: Context) {
            val i = Intent(ctx, CallForegroundService::class.java)
            ctx.stopService(i)
        }
    }
}
