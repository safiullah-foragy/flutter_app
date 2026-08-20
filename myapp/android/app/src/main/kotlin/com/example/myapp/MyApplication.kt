package com.example.myapp

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build

class MyApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        initNotificationChannels()
        try {
            MessageWatcherService.start(this)
        } catch (_: Throwable) {}
    }

    private fun initNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val nm = getSystemService(NotificationManager::class.java) ?: return

                // 1. Calls channel (Ringtone sound, continuous vibration, max priority)
                val callSoundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                val callAudioAttributes = AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .build()

                val callsChannel = NotificationChannel("calls", "Incoming Calls", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Incoming call ringing and alerts"
                    setSound(callSoundUri, callAudioAttributes)
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 1000, 1000, 1000, 1000)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setBypassDnd(true)
                }
                nm.createNotificationChannel(callsChannel)

                // 2. Messages popup channel (Notification sound, vibration)
                val msgSoundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                val msgAudioAttributes = AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .build()

                val messagesPopup = NotificationChannel("messages_popup_v2", "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Message popup notifications with sound"
                    setSound(msgSoundUri, msgAudioAttributes)
                    enableVibration(true)
                    vibrationPattern = longArrayOf(0, 250, 200, 250)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setShowBadge(true)
                    setBypassDnd(true)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) messagesPopup.setAllowBubbles(true)
                nm.createNotificationChannel(messagesPopup)

                // 3. Default messages channel
                val messagesDefault = NotificationChannel("messages", "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Incoming messages"
                    setSound(msgSoundUri, msgAudioAttributes)
                    enableVibration(true)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setShowBadge(true)
                }
                nm.createNotificationChannel(messagesDefault)

            } catch (_: Throwable) {}
        }
    }
}
