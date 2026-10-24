package com.dropmate.dropmate

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat

/** "Buzz": rings on the alarm stream at full volume (so it plays on silent) and vibrates, for up to 30 s. */
object Buzz {
    private const val CHANNEL = "buzz"
    private const val ID = 2
    private var ring: Ringtone? = null
    private var vib: Vibrator? = null
    private var savedVolume = -1
    private val main = Handler(Looper.getMainLooper())

    private val alarm: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    fun start(ctx: Context, from: String) {
        stop(ctx, tellDart = false)
        val am = ctx.getSystemService(AudioManager::class.java)
        savedVolume = am.getStreamVolume(AudioManager.STREAM_ALARM)
        try {
            am.setStreamVolume(AudioManager.STREAM_ALARM, am.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0)
        } catch (_: Exception) {
            // Do Not Disturb can refuse volume changes; it still rings at the current alarm volume.
        }
        val uri = RingtoneManager.getActualDefaultRingtoneUri(ctx, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        ring = RingtoneManager.getRingtone(ctx, uri)?.apply {
            audioAttributes = alarm
            if (Build.VERSION.SDK_INT >= 28) isLooping = true
            play()
        }
        @Suppress("DEPRECATION")
        val v = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(VibratorManager::class.java).defaultVibrator
        else ctx.getSystemService(Vibrator::class.java)
        @Suppress("DEPRECATION")
        v?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 700, 500), 0), alarm)
        vib = v

        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Buzz", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Someone is looking for this phone"
                setSound(null, null) // the alarm above makes the noise
            })
        val stop = PendingIntent.getBroadcast(
            ctx, 0, Intent(ctx, BuzzStopReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(
            ctx, 0, Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        nm.notify(ID, NotificationCompat.Builder(ctx, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("$from is buzzing you")
            .setContentText("Tap Stop when you've found it")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setContentIntent(open)
            .setDeleteIntent(stop)
            .addAction(0, "Stop", stop)
            .setOngoing(true)
            .build())
        main.postDelayed({ stop(ctx) }, 30_000)
    }

    fun stop(ctx: Context, tellDart: Boolean = true) {
        main.removeCallbacksAndMessages(null)
        val was = ring != null || vib != null
        ring?.stop()
        ring = null
        vib?.cancel()
        vib = null
        if (savedVolume >= 0) {
            try {
                ctx.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, savedVolume, 0)
            } catch (_: Exception) {
            }
            savedVolume = -1
        }
        ctx.getSystemService(NotificationManager::class.java).cancel(ID)
        if (was && tellDart) Bridge.buzzStopped()
    }
}

class BuzzStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = Buzz.stop(context.applicationContext)
}
