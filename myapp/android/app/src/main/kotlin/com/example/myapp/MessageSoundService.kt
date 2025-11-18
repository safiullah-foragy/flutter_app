package com.example.myapp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.MediaPlayer
import android.media.AudioAttributes
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import android.content.res.AssetFileDescriptor

/**
 * Foreground service that briefly plays the user's selected message ringtone asset,
 * so custom sound works even when the app is closed/locked.
 */
class MessageSoundService : Service() {
    private var mediaPlayer: MediaPlayer? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val assetPath = intent?.getStringExtra(EXTRA_ASSET_PATH)
        val durationMs = intent?.getIntExtra(EXTRA_DURATION_MS, 6000) ?: 6000
        startForegroundInternal()
        startSound(assetPath, durationMs)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        stopSound()
    }

    private fun startForegroundInternal() {
        val channelId = CHANNEL_ID
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(channelId, "Message Sound", NotificationManager.IMPORTANCE_LOW)
                ch.setSound(null, null)
                ch.setShowBadge(false)
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
            .setContentTitle("Playing message tone")
            .setContentText("")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(pi)
            .build()
        startForeground(NOTIF_ID, notif)
    }

    private fun startSound(assetPath: String?, durationMs: Int) {
        try {
            stopSound()
            val ap = assetPath ?: "Assets/mp3 file/Iphone-Notification.mp3"
            val afd: AssetFileDescriptor = assets.openFd("flutter_assets/" + ap)
            mediaPlayer = MediaPlayer()
            mediaPlayer?.setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                mediaPlayer?.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
            }
            mediaPlayer?.isLooping = false
            mediaPlayer?.setVolume(1.0f, 1.0f)
            mediaPlayer?.prepare()
            mediaPlayer?.setOnCompletionListener {
                stopSelf()
            }
            mediaPlayer?.start()
            // Schedule a stop in durationMs
            val handler = android.os.Handler(mainLooper)
            handler.postDelayed({ stopSelf() }, durationMs.toLong())
        } catch (_: Throwable) {
            stopSelf()
        }
    }

    private fun stopSound() {
        try { mediaPlayer?.stop() } catch (_: Throwable) {}
        try { mediaPlayer?.release() } catch (_: Throwable) {}
        mediaPlayer = null
    }

    companion object {
        private const val CHANNEL_ID = "msg_sound"
        private const val NOTIF_ID = 2002
        private const val EXTRA_ASSET_PATH = "assetPath"
        private const val EXTRA_DURATION_MS = "durationMs"

        fun start(ctx: Context, assetPath: String?, durationMs: Int = 6000) {
            val i = Intent(ctx, MessageSoundService::class.java)
            if (assetPath != null) i.putExtra(EXTRA_ASSET_PATH, assetPath)
            i.putExtra(EXTRA_DURATION_MS, durationMs)
            ContextCompat.startForegroundService(ctx, i)
        }
        fun stop(ctx: Context) {
            val i = Intent(ctx, MessageSoundService::class.java)
            ctx.stopService(i)
        }
    }
}
