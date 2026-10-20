package app.lanshare.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class TransferForegroundService : Service() {
    private var cpuLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL_ID, "파일 전송", NotificationManager.IMPORTANCE_LOW).apply {
                description = "화면이 꺼져도 파일 전송을 계속합니다"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val label = intent?.getStringExtra(EXTRA_LABEL) ?: "파일 전송 중"
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("LanShare 파일 전송")
            .setContentText(label)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireLocks()
        return START_NOT_STICKY
    }

    private fun acquireLocks() {
        val power = getSystemService(POWER_SERVICE) as PowerManager
        cpuLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:LanShareTransfer").apply {
            setReferenceCounted(false)
            if (!isHeld) acquire()
        }
        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "$packageName:LanShareTransferWifi").apply {
            setReferenceCounted(false)
            if (!isHeld) acquire()
        }
    }

    override fun onDestroy() {
        try { if (cpuLock?.isHeld == true) cpuLock?.release() } catch (_: Exception) { }
        try { if (wifiLock?.isHeld == true) wifiLock?.release() } catch (_: Exception) { }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        const val ACTION_START = "app.lanshare.android.action.START_TRANSFER"
        const val EXTRA_LABEL = "transfer_label"
        private const val CHANNEL_ID = "lanshare_transfer"
        private const val NOTIFICATION_ID = 201
    }
}
