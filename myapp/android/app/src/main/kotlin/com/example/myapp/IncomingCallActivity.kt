package com.example.myapp

import android.annotation.SuppressLint
import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.google.firebase.FirebaseApp
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.ListenerRegistration
import com.google.firebase.firestore.SetOptions
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Full-screen incoming call Activity.
 * Extends plain Activity (not AppCompatActivity) to avoid dependency issues.
 * Shows on lock screen / over other apps even when the Flutter app is killed.
 */
class IncomingCallActivity : Activity() {

    private var sessionListener: ListenerRegistration? = null
    private var cancelReceiver: BroadcastReceiver? = null

    @SuppressLint("SetTextI18n")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Show over lock screen and wake the screen
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val km = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
            km.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                        WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }

        val density = resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        // Root layout
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setBackgroundColor(0xFF1A1A2E.toInt())
        root.gravity = Gravity.CENTER
        val p = dp(32)
        root.setPadding(p, p, p, p)
        setContentView(root)

        // Avatar
        val avatarView = ImageView(this)
        val avSize = dp(180)
        val avLp = LinearLayout.LayoutParams(avSize, avSize)
        avLp.gravity = Gravity.CENTER_HORIZONTAL
        avLp.bottomMargin = dp(28)
        avatarView.layoutParams = avLp
        avatarView.setImageResource(R.mipmap.ic_launcher)
        avatarView.scaleType = ImageView.ScaleType.CENTER_CROP
        root.addView(avatarView)

        // Call type label
        val callTypeText = TextView(this)
        callTypeText.text = if (intent.getBooleanExtra(EXTRA_VIDEO, false)) "Incoming video call" else "Incoming audio call"
        callTypeText.setTextColor(0xFFCCCCCC.toInt())
        callTypeText.textSize = 14f
        callTypeText.gravity = Gravity.CENTER
        val ctLp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        ctLp.bottomMargin = dp(8)
        callTypeText.layoutParams = ctLp
        root.addView(callTypeText)

        // Caller name
        val callerNameText = TextView(this)
        callerNameText.text = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "Incoming Call"
        callerNameText.setTextColor(0xFFFFFFFF.toInt())
        callerNameText.textSize = 28f
        callerNameText.setTypeface(null, android.graphics.Typeface.BOLD)
        callerNameText.gravity = Gravity.CENTER
        val cnLp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        cnLp.bottomMargin = dp(56)
        callerNameText.layoutParams = cnLp
        root.addView(callerNameText)

        // Button row
        val btnRow = LinearLayout(this)
        btnRow.orientation = LinearLayout.HORIZONTAL
        btnRow.gravity = Gravity.CENTER
        btnRow.layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)

        val declineBtn = Button(this)
        declineBtn.text = "Decline"
        declineBtn.setBackgroundColor(0xFFE53935.toInt())
        declineBtn.setTextColor(0xFFFFFFFF.toInt())
        declineBtn.textSize = 16f
        val dLp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        dLp.marginEnd = dp(12)
        declineBtn.layoutParams = dLp
        declineBtn.setOnClickListener { handleDecline() }

        val acceptBtn = Button(this)
        acceptBtn.text = "Accept"
        acceptBtn.setBackgroundColor(0xFF43A047.toInt())
        acceptBtn.setTextColor(0xFFFFFFFF.toInt())
        acceptBtn.textSize = 16f
        val aLp = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        aLp.marginStart = dp(12)
        acceptBtn.layoutParams = aLp
        acceptBtn.setOnClickListener { handleAccept() }

        btnRow.addView(declineBtn)
        btnRow.addView(acceptBtn)
        root.addView(btnRow)

        // Load photo in background
        val photoUrl = intent.getStringExtra(EXTRA_PHOTO_URL)
        if (!photoUrl.isNullOrEmpty()) {
            thread {
                val bmp = downloadCircularBitmap(photoUrl)
                if (bmp != null) runOnUiThread { avatarView.setImageBitmap(bmp) }
            }
        }

        // Start ringtone
        try { FirebaseApp.initializeApp(this) } catch (_: Throwable) {}
        val callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: ""
        val isVideo = intent.getBooleanExtra(EXTRA_VIDEO, false)
        val flutterPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val silent = flutterPrefs.getBoolean("flutter.ringtone_call_silent", false)
        val assetPath = flutterPrefs.getString("flutter.ringtone_call", "Assets/mp3 file/lovely-Alarm.mp3")
        if (!silent) {
            CallForegroundService.start(
                this,
                if (isVideo) "Incoming video call" else "Incoming audio call",
                callerName, isVideo, ring = true, assetPath = assetPath
            )
        }

        // Cancel receiver
        val thisActivity = this
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, broadcastIntent: Intent) {
                if (broadcastIntent.action == ACTION_CANCEL_INCOMING_CALL) {
                    thisActivity.stopRinging()
                    if (!thisActivity.isFinishing) thisActivity.finish()
                }
            }
        }
        cancelReceiver = receiver
        val filter = IntentFilter(ACTION_CANCEL_INCOMING_CALL)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }

        // Watch Firestore
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID)
        if (!sessionId.isNullOrEmpty()) {
            sessionListener = FirebaseFirestore.getInstance()
                .collection("call_sessions")
                .document(sessionId)
                .addSnapshotListener { snap, _ ->
                    if (snap == null) return@addSnapshotListener
                    if (!snap.exists()) {
                        thisActivity.runOnUiThread {
                            thisActivity.stopRinging()
                            if (!thisActivity.isFinishing) thisActivity.finish()
                        }
                        return@addSnapshotListener
                    }
                    val status = snap.getString("status") ?: return@addSnapshotListener
                    if (status != "ringing" && status != "accepted") {
                        thisActivity.runOnUiThread {
                            thisActivity.stopRinging()
                            if (!thisActivity.isFinishing) thisActivity.finish()
                        }
                    }
                }
        }
    }

    private fun handleDecline() {
        stopRinging()
        cancelCallNotification()
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: ""
        val calleeId = intent.getStringExtra(EXTRA_CALLEE_ID) ?: ""
        if (sessionId.isNotEmpty()) {
            val updates = hashMapOf<String, Any>("status" to "rejected", "ended_at" to System.currentTimeMillis())
            if (calleeId.isNotEmpty()) updates["ended_by"] = calleeId
            FirebaseFirestore.getInstance().collection("call_sessions").document(sessionId).set(updates, SetOptions.merge())
        }
        finish()
    }

    private fun handleAccept() {
        stopRinging()
        cancelCallNotification()
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: ""
        val channel = intent.getStringExtra(EXTRA_CHANNEL) ?: ""
        val callerId = intent.getStringExtra(EXTRA_CALLER_ID) ?: ""
        val callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: ""
        val isVideo = intent.getBooleanExtra(EXTRA_VIDEO, false)
        val calleeId = intent.getStringExtra(EXTRA_CALLEE_ID) ?: ""

        if (sessionId.isNotEmpty()) {
            FirebaseFirestore.getInstance().collection("call_sessions").document(sessionId)
                .set(hashMapOf<String, Any>("status" to "accepted", "accepted_at" to System.currentTimeMillis()), SetOptions.merge())
        }

        val mainIntent = Intent(this, MainActivity::class.java)
        mainIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        mainIntent.action = CallActionReceiver.ACTION_ACCEPT
        mainIntent.putExtra("call_channel", channel)
        mainIntent.putExtra("caller_id", callerId)
        mainIntent.putExtra("caller_name", callerName)
        mainIntent.putExtra("callee_id", calleeId)
        mainIntent.putExtra("video", isVideo)
        mainIntent.putExtra("call_session_id", sessionId)
        mainIntent.putExtra("auto_accept_call", true)
        startActivity(mainIntent)
        finish()
    }

    internal fun stopRinging() {
        try { CallForegroundService.stop(this) } catch (_: Throwable) {}
    }

    private fun cancelCallNotification() {
        try {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).cancel(CallActionReceiver.NOTIF_ID)
        } catch (_: Throwable) {}
    }

    override fun onDestroy() {
        sessionListener?.remove()
        try { cancelReceiver?.let { unregisterReceiver(it) } } catch (_: Throwable) {}
        super.onDestroy()
    }

    @Suppress("OVERRIDE_DEPRECATION", "MissingSuperCall")
    override fun onBackPressed() {
        // Block back navigation — user must Accept or Decline
    }

    private fun downloadCircularBitmap(urlStr: String): Bitmap? {
        return try {
            val conn = URL(urlStr).openConnection() as HttpURLConnection
            conn.doInput = true; conn.connectTimeout = 5000; conn.readTimeout = 5000; conn.connect()
            val original = BitmapFactory.decodeStream(conn.inputStream)
            conn.disconnect()
            if (original != null) makeCircular(original) else null
        } catch (_: Throwable) { null }
    }

    private fun makeCircular(src: Bitmap): Bitmap {
        val s = minOf(src.width, src.height)
        val out = Bitmap.createBitmap(s, s, Bitmap.Config.ARGB_8888)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val x = (src.width - s) / 2; val y = (src.height - s) / 2
        paint.shader = BitmapShader(Bitmap.createBitmap(src, x, y, s, s), Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        Canvas(out).drawCircle(s / 2f, s / 2f, s / 2f, paint)
        return out
    }

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
        const val EXTRA_CHANNEL = "call_channel"
        const val EXTRA_CALLER_ID = "caller_id"
        const val EXTRA_CALLER_NAME = "caller_name"
        const val EXTRA_CALLEE_ID = "callee_id"
        const val EXTRA_VIDEO = "video"
        const val EXTRA_PHOTO_URL = "photo_url"
        const val ACTION_CANCEL_INCOMING_CALL = "com.example.myapp.ACTION_CANCEL_INCOMING_CALL"

        fun launch(ctx: Context, sessionId: String, channel: String, callerId: String,
                   callerName: String, calleeId: String, isVideo: Boolean, photoUrl: String?) {
            val i = Intent(ctx, IncomingCallActivity::class.java)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            i.putExtra(EXTRA_SESSION_ID, sessionId)
            i.putExtra(EXTRA_CHANNEL, channel)
            i.putExtra(EXTRA_CALLER_ID, callerId)
            i.putExtra(EXTRA_CALLER_NAME, callerName)
            i.putExtra(EXTRA_CALLEE_ID, calleeId)
            i.putExtra(EXTRA_VIDEO, isVideo)
            if (!photoUrl.isNullOrEmpty()) i.putExtra(EXTRA_PHOTO_URL, photoUrl)
            ctx.startActivity(i)
        }
    }
}
