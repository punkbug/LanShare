package app.lanshare.android

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import android.view.Gravity
import android.text.InputFilter
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import java.text.DecimalFormat
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.max

private const val SERVICE_TYPE = "_lanshare._tcp."
private const val PICK_FILE = 1001

private data class Peer(val code: String, val host: String, val port: Int)

class MainActivity : Activity() {
    private val executor = Executors.newCachedThreadPool()
    private val peers = ConcurrentHashMap<String, Peer>()
    private lateinit var root: LinearLayout
    private lateinit var peerList: LinearLayout
    private lateinit var statusText: TextView
    private lateinit var transferText: TextView
    private lateinit var transferDetails: TextView
    private lateinit var progressBar: ProgressBar
    private lateinit var codeInput: EditText
    private lateinit var sendButton: Button
    private lateinit var nsd: NsdManager
    private lateinit var wifiLock: WifiManager.MulticastLock
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var serverSocket: ServerSocket? = null
    private var chosenUri: android.net.Uri? = null
    private var chosenName: String? = null
    private var chosenSize: Long = 0
    @Volatile private var activeSocket: Socket? = null
    private var transferInProgress = false
    private var selectedPeer: Peer? = null
    private val localCode = (1000..9999).random().toString()
    private val serviceName: String by lazy { "LanShare-$localCode" }
    private val deviceName: String by lazy { readDeviceName() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        nsd = getSystemService(NSD_SERVICE) as NsdManager
        buildScreen()
        startNetworking()
    }

    private fun buildScreen() {
        val scroll = ScrollView(this)
        root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(22), dp(24), dp(22), dp(24))
            setBackgroundColor(Color.rgb(246, 248, 252))
        }
        scroll.addView(root)
        setContentView(scroll)

        text("⇅  LanShare", 28, Color.rgb(24, 39, 64), true).also { root.addView(it) }
        text("같은 네트워크에서 파일을 바로 주고받으세요", 14, Color.rgb(100, 111, 130)).also {
            root.addView(it, margin(bottom = 14))
        }

        val codeCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background = rounded(Color.WHITE, 14)
            addView(text("내 연결 코드", 13, Color.rgb(100, 111, 130)))
            addView(text(localCode, 34, Color.rgb(41, 98, 255), true), margin(top = 2))
            addView(text("같은 네트워크의 상대방이 이 코드를 입력하면 연결됩니다.", 12, Color.rgb(100, 111, 130)), margin(top = 3))
        }
        root.addView(codeCard, margin(bottom = 14))

        text("상대방 코드 입력", 16, Color.rgb(24, 39, 64), true).also { root.addView(it) }
        val codeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        codeInput = EditText(this).apply {
            hint = "4자리 코드"
            inputType = InputType.TYPE_CLASS_NUMBER
            filters = arrayOf(InputFilter.LengthFilter(4))
            textSize = 20f
            gravity = Gravity.CENTER
        }
        codeRow.addView(codeInput, LinearLayout.LayoutParams(0, dp(52), 1f).apply { rightMargin = dp(8) })
        codeRow.addView(Button(this).apply {
            text = "코드 연결"
            setOnClickListener { connectByCode() }
        }, LinearLayout.LayoutParams(dp(120), dp(52)))
        root.addView(codeRow, margin(top = 4, bottom = 8))
        text("두 기기가 같은 Wi-Fi 또는 로컬 네트워크에 연결되어 있어야 합니다.", 12, Color.rgb(100, 111, 130))
            .also { root.addView(it, margin(bottom = 14)) }

        val warning = text("개발용 초안 · 전송 암호화가 적용되지 않았습니다. 신뢰하는 네트워크에서만 사용하세요.", 13, Color.rgb(130, 79, 0))
        warning.setPadding(dp(14), dp(12), dp(14), dp(12))
        warning.background = rounded(Color.rgb(255, 239, 204), 12)
        root.addView(warning, margin(bottom = 22))

        text("주변 기기", 18, Color.rgb(24, 39, 64), true).also { root.addView(it) }
        peerList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(peerList, margin(top = 8, bottom = 16))

        val refresh = Button(this).apply {
            text = "주변 기기 새로고침"
            setOnClickListener { restartDiscovery() }
        }
        root.addView(refresh, matchWidth())

        val divider = View(this).apply { setBackgroundColor(Color.rgb(225, 230, 239)) }
        root.addView(divider, LinearLayout.LayoutParams(matchWidth().width, dp(1)).apply {
            topMargin = dp(24); bottomMargin = dp(24)
        })

        text("파일 보내기", 18, Color.rgb(24, 39, 64), true).also { root.addView(it) }
        text("한 번에 하나의 파일을 보냅니다.", 13, Color.rgb(100, 111, 130)).also {
            root.addView(it, margin(top = 4, bottom = 12))
        }
        val choose = Button(this).apply {
            text = "파일 선택"
            setOnClickListener {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                startActivityForResult(intent, PICK_FILE)
            }
        }
        root.addView(choose, matchWidth())
        sendButton = Button(this).apply {
            text = "코드 연결 후 파일 보내기"
            isEnabled = false
            setOnClickListener { selectedPeer?.let(::sendFile) }
        }
        root.addView(sendButton, margin(top = 8))
        transferText = text("선택한 파일 없음", 14, Color.rgb(67, 78, 97))
        root.addView(transferText, margin(top = 10))
        transferDetails = text("", 12, Color.rgb(100, 111, 130))
        transferDetails.visibility = View.GONE
        root.addView(transferDetails, margin(top = 4))
        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 1000
            visibility = View.GONE
        }
        root.addView(progressBar, margin(top = 6))
        statusText = text("같은 Wi-Fi에서 LanShare 기기를 찾는 중…", 13, Color.rgb(100, 111, 130))
        root.addView(statusText, margin(top = 18))
    }

    private fun startNetworking() {
        try {
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            wifiLock = wifi.createMulticastLock("LanShare-mDNS").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) { }
        startServer()
        registerService()
        startDiscovery()
    }

    private fun startServer() {
        executor.execute {
            try {
                val socketServer = ServerSocket(0)
                serverSocket = socketServer
                runOnUiThread { statusText.text = "같은 네트워크의 기기 코드를 검색 중입니다" }
                while (!socketServer.isClosed) {
                    val socket = socketServer.accept()
                    executor.execute { handleIncoming(socket) }
                }
            } catch (e: Exception) {
                if (!isFinishing) runOnUiThread { statusText.text = "수신 서버 오류: ${e.localizedMessage ?: "알 수 없는 오류"}" }
            }
        }
    }

    private fun registerService() {
        executor.execute {
            while (serverSocket == null && !isFinishing) Thread.sleep(50)
            val port = serverSocket?.localPort ?: return@execute
            val info = NsdServiceInfo().apply {
                this.serviceName = this@MainActivity.serviceName
                serviceType = SERVICE_TYPE
                setPort(port)
            }
            runOnUiThread {
                try {
                    nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, object : NsdManager.RegistrationListener {
                        override fun onServiceRegistered(service: NsdServiceInfo) {
                            registrationListener = this
                            statusText.text = "내 코드 ${localCode}를 주변 기기에 알렸습니다"
                        }
                        override fun onRegistrationFailed(service: NsdServiceInfo, errorCode: Int) {
                            statusText.text = "주변 기기에 표시하지 못했습니다 ($errorCode)"
                        }
                        override fun onServiceUnregistered(service: NsdServiceInfo) { }
                        override fun onUnregistrationFailed(service: NsdServiceInfo, errorCode: Int) { }
                    }.also { registrationListener = it })
                } catch (e: Exception) { statusText.text = "기기 알림을 시작하지 못했습니다: ${e.localizedMessage}" }
            }
        }
    }

    private fun startDiscovery() {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                runOnUiThread { statusText.text = "같은 네트워크의 기기 코드를 검색 중입니다" }
            }
            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceType.trimEnd('.') != SERVICE_TYPE.trimEnd('.') || service.serviceName == serviceName) return
                val code = service.serviceName.removePrefix("LanShare-").takeIf { it.matches(Regex("\\d{4}")) } ?: return
                try {
                    nsd.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { }
                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                            val host = serviceInfo.host?.hostAddress ?: return
                            val resolvedCode = serviceInfo.serviceName.removePrefix("LanShare-").takeIf { it.matches(Regex("\\d{4}")) } ?: code
                            if (resolvedCode == localCode) return
                            val peer = Peer(resolvedCode, host, serviceInfo.port)
                            peers[serviceInfo.serviceName] = peer
                            runOnUiThread {
                                if (codeInput.text.toString() == resolvedCode) connectByCode()
                                else renderPeers()
                            }
                        }
                    })
                } catch (_: IllegalArgumentException) { }
            }
            override fun onServiceLost(service: NsdServiceInfo) {
                peers.remove(service.serviceName)
                runOnUiThread { renderPeers() }
            }
            override fun onDiscoveryStopped(serviceType: String) { }
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                nsd.stopServiceDiscovery(this)
                runOnUiThread { statusText.text = "기기 검색을 시작하지 못했습니다 ($errorCode)" }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) { nsd.stopServiceDiscovery(this) }
        }
        discoveryListener = listener
        try { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
        catch (e: Exception) { statusText.text = "기기 검색을 시작하지 못했습니다: ${e.localizedMessage}" }
    }

    private fun restartDiscovery() {
        discoveryListener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) { } }
        peers.clear()
        selectedPeer = null
        renderPeers()
        startDiscovery()
    }

    private fun connectByCode() {
        val code = codeInput.text.toString().trim()
        if (!code.matches(Regex("\\d{4}"))) {
            statusText.text = "상대방의 4자리 코드를 입력하세요"
            selectedPeer = null
            renderPeers()
            return
        }
        val matches = peers.values.filter { it.code == code }
        selectedPeer = when (matches.size) {
            0 -> null
            1 -> matches.first()
            else -> null
        }
        statusText.text = when (matches.size) {
            0 -> "코드 $code 기기를 찾지 못했습니다. 같은 네트워크인지 확인하고 새로고침하세요."
            1 -> "코드 $code 기기에 연결했습니다. 파일을 선택해 보내세요."
            else -> "같은 코드 기기가 여러 대입니다. 상대 기기에서 새 코드를 발급하세요."
        }
        renderPeers()
    }

    private fun renderPeers() {
        peerList.removeAllViews()
        val found = peers.values.sortedBy { it.code }
        if (found.isEmpty()) {
            peerList.addView(text("기기 코드 검색 중… 상대방도 앱을 열고 같은 네트워크에 연결하세요.", 13, Color.rgb(100, 111, 130)))
            sendButton.isEnabled = false
            return
        }
        found.forEach { peer ->
            val button = Button(this).apply {
                text = "LanShare · 코드 ${peer.code}"
                isEnabled = !transferInProgress
                setOnClickListener { codeInput.setText(peer.code); connectByCode() }
            }
            peerList.addView(button, margin(bottom = 8).also { it.width = matchWidth().width })
        }
        sendButton.isEnabled = chosenUri != null && selectedPeer != null && !transferInProgress
    }

    private fun updateSendButton() {
        sendButton.isEnabled = chosenUri != null && selectedPeer != null && !transferInProgress
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILE || resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        val name = queryName(uri) ?: "파일"
        val size = querySize(uri)
        chosenUri = uri
        chosenName = name
        chosenSize = size
        transferText.text = if (size >= 0) "$name · ${formatBytes(size)}" else "$name · 크기 확인 불가"
        renderPeers()
    }

    private fun sendFile(peer: Peer) {
        val uri = chosenUri ?: return
        val name = chosenName ?: "file"
        val size = chosenSize
        if (size < 0) {
            statusText.text = "선택한 파일의 크기를 확인할 수 없어 전송할 수 없습니다"
            return
        }
        ensureNotificationPermission()
        startTransferKeepAlive("코드 ${peer.code} 기기에 보내는 중")
        setTransferState(true, "코드 ${peer.code} 기기에 연결 중…", 0)
        executor.execute {
            try {
                val socket = Socket(peer.host, peer.port)
                activeSocket = socket
                socket.tcpNoDelay = true
                val request = JSONObject().apply {
                    put("version", 1)
                put("sender", deviceName)
                    put("fileName", name)
                    put("size", size)
                }
                val output = socket.getOutputStream()
                output.write((request.toString() + "\n").toByteArray(StandardCharsets.UTF_8))
                output.flush()
                val response = BufferedReader(InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8)).readLine()
                if (response != "ACCEPT") throw IllegalStateException(if (response == "REJECT") "상대 기기가 전송을 거절했습니다" else "상대 기기에서 응답이 없습니다")
                val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("선택한 파일을 열 수 없습니다")
                input.use { source ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    val startedAt = SystemClock.elapsedRealtime()
                    var lastUiUpdate = 0L
                    while (total < size) {
                        val count = source.read(buffer, 0, minOf(buffer.size.toLong(), size - total).toInt())
                        if (count < 0) throw IllegalStateException("파일을 읽는 중 예상보다 일찍 끝났습니다")
                        if (count == 0) continue
                        output.write(buffer, 0, count)
                        total += count
                        val now = SystemClock.elapsedRealtime()
                        if (now - lastUiUpdate >= 150 || total == size) {
                            updateProgress("보내는 중 · $name", total, size, startedAt)
                            lastUiUpdate = now
                        }
                    }
                    output.flush()
                }
                socket.shutdownOutput()
                socket.close()
                activeSocket = null
                stopTransferKeepAlive()
                setTransferState(false, "전송 완료 · $name", 1000)
            } catch (e: Exception) {
                activeSocket?.close()
                activeSocket = null
                stopTransferKeepAlive()
                setTransferState(false, e.localizedMessage ?: "전송에 실패했습니다", 0)
            }
        }
    }

    private fun handleIncoming(socket: Socket) {
        activeSocket = socket
        var keepAliveStarted = false
        try {
            socket.soTimeout = 120_000
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8))
            val line = reader.readLine() ?: throw IllegalStateException("전송 요청을 읽지 못했습니다")
            require(line.toByteArray(StandardCharsets.UTF_8).size <= 4096) { "요청이 너무 큽니다" }
            val json = JSONObject(line)
            require(json.optInt("version") == 1) { "지원하지 않는 전송 프로토콜입니다" }
            val sender = json.optString("sender", "알 수 없는 기기")
            val rawName = json.optString("fileName", "")
            val name = safeName(rawName) ?: throw IllegalArgumentException("잘못된 파일 이름입니다")
            val size = json.optLong("size", -1)
            require(size in 0..100_000_000_000L) { "허용되지 않는 파일 크기입니다" }

            val decision = CountDownLatch(1)
            val accepted = booleanArrayOf(false)
            runOnUiThread {
                if (isFinishing || isDestroyed) { decision.countDown(); return@runOnUiThread }
                AlertDialog.Builder(this)
                    .setTitle("파일 전송 요청")
                    .setMessage("$sender 기기에서 $name (${formatBytes(size)}) 파일을 보내려 합니다.")
                    .setPositiveButton("받기") { _, _ ->
                        accepted[0] = true
                        ensureNotificationPermission()
                        decision.countDown()
                    }
                    .setNegativeButton("거절") { _, _ -> decision.countDown() }
                    .setOnCancelListener { decision.countDown() }
                    .show()
            }
            if (!decision.await(2, TimeUnit.MINUTES) || !accepted[0]) {
                socket.getOutputStream().write("REJECT\n".toByteArray(StandardCharsets.UTF_8))
                socket.close()
                return
            }

            startTransferKeepAlive("$name 받는 중")
            keepAliveStarted = true

            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, uniqueDisplayName(name))
                val extension = android.webkit.MimeTypeMap.getFileExtensionFromUrl(name).lowercase(Locale.ROOT)
                put(MediaStore.Downloads.MIME_TYPE, android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/LanShare")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val destination = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("다운로드 폴더에 파일을 만들 수 없습니다")
            try {
                val output = contentResolver.openOutputStream(destination, "w")
                    ?: throw IllegalStateException("저장 파일을 열 수 없습니다")
                socket.getOutputStream().write("ACCEPT\n".toByteArray(StandardCharsets.UTF_8))
                socket.getOutputStream().flush()
                output.use { target ->
                    val input = socket.getInputStream()
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    val startedAt = SystemClock.elapsedRealtime()
                    var lastUiUpdate = 0L
                    while (total < size) {
                        val count = input.read(buffer, 0, minOf(buffer.size.toLong(), size - total).toInt())
                        if (count < 0) throw IllegalStateException("파일을 다 받기 전에 연결이 끝났습니다")
                        if (count == 0) continue
                        target.write(buffer, 0, count)
                        total += count
                        val now = SystemClock.elapsedRealtime()
                        if (now - lastUiUpdate >= 150 || total == size) {
                            updateProgress("받는 중 · $name", total, size, startedAt)
                            lastUiUpdate = now
                        }
                    }
                }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                contentResolver.update(destination, values, null, null)
                runOnUiThread { setTransferState(false, "다운로드에 저장했습니다 · $name", 1000) }
            } catch (e: Exception) {
                contentResolver.delete(destination, null, null)
                throw e
            }
            socket.close()
            stopTransferKeepAlive()
            keepAliveStarted = false
        } catch (e: Exception) {
            try { socket.close() } catch (_: Exception) { }
            if (keepAliveStarted) stopTransferKeepAlive()
            if (!isFinishing) runOnUiThread { setTransferState(false, e.localizedMessage ?: "수신에 실패했습니다", 0) }
        } finally { activeSocket = null }
    }

    private fun uniqueDisplayName(original: String): String {
        val lastDot = original.lastIndexOf('.')
        val stem = if (lastDot > 0) original.substring(0, lastDot) else original
        val extension = if (lastDot > 0) original.substring(lastDot) else ""
        for (index in 1..10_000) {
            val candidate = if (index == 1) original else "$stem ($index)$extension"
            val exists = contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.DISPLAY_NAME}=? AND ${MediaStore.Downloads.RELATIVE_PATH}=?",
                arrayOf(candidate, "Download/LanShare/"),
                null
            )?.use { it.moveToFirst() } ?: false
            if (!exists) return candidate
        }
        return "${System.currentTimeMillis()}-$original"
    }

    private fun safeName(value: String): String? {
        if (value.isBlank() || value == "." || value == ".." || value.length > 240) return null
        if (value.any { it == '/' || it == '\\' || it == ':' || it.code < 32 }) return null
        return value
    }

    private fun queryName(uri: android.net.Uri): String? = contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else null
    }

    private fun querySize(uri: android.net.Uri): Long = contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else -1L
    } ?: -1L

    private fun updateProgress(label: String, done: Long, size: Long, startedAt: Long) {
        val value = if (size <= 0) 1000 else ((done.toDouble() / size) * 1000).toInt().coerceIn(0, 1000)
        val elapsedSeconds = ((SystemClock.elapsedRealtime() - startedAt).coerceAtLeast(1)) / 1000.0
        val bytesPerSecond = done / elapsedSeconds
        val remainingSeconds = if (bytesPerSecond > 0) ((size - done).coerceAtLeast(0) / bytesPerSecond).toLong() else 0L
        val details = if (done == 0L) "속도 계산 중…" else "${formatBytes(bytesPerSecond.toLong())}/s · 남은 시간 ${formatDuration(remainingSeconds)}"
        runOnUiThread { setTransferState(true, label, value, details) }
    }

    private fun setTransferState(active: Boolean, label: String, value: Int, details: String = "") {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            runOnUiThread { setTransferState(active, label, value, details) }
            return
        }
        transferInProgress = active
        transferText.text = label
        transferDetails.text = details
        transferDetails.visibility = if (details.isBlank()) View.GONE else View.VISIBLE
        progressBar.visibility = if (active || value > 0) View.VISIBLE else View.GONE
        progressBar.progress = value
        statusText.text = if (active) "전송 중입니다" else label
        renderPeers()
    }

    private fun formatBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var amount = bytes.toDouble()
        var index = -1
        do { amount /= 1024.0; index++ } while (amount >= 1024 && index < units.lastIndex)
        return "${DecimalFormat("#,##0.0").format(amount)} ${units[index]}"
    }

    private fun formatDuration(seconds: Long): String = when {
        seconds < 60 -> "${seconds.coerceAtLeast(1)}초"
        seconds < 3600 -> "${seconds / 60}분 ${seconds % 60}초"
        seconds < 86400 -> "${seconds / 3600}시간 ${(seconds % 3600) / 60}분"
        else -> "${seconds / 86400}일 ${(seconds % 86400) / 3600}시간"
    }

    private fun readDeviceName(): String {
        val candidates = listOf(
            runCatching { Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull(),
            runCatching { Settings.Secure.getString(contentResolver, "bluetooth_name") }.getOrNull(),
            "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}"
        )
        return candidates.firstOrNull { !it.isNullOrBlank() }!!.trim().take(48)
    }

    private fun startTransferKeepAlive(label: String) {
        val intent = Intent(this, TransferForegroundService::class.java)
            .setAction(TransferForegroundService.ACTION_START)
            .putExtra(TransferForegroundService.EXTRA_LABEL, label)
        if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
    }

    private fun ensureNotificationPermission() {
        if (android.os.Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2001)
        }
    }

    private fun stopTransferKeepAlive() {
        stopService(Intent(this, TransferForegroundService::class.java))
    }

    private fun text(value: String, size: Int, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = value
        textSize = size.toFloat()
        setTextColor(color)
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun rounded(color: Int, radius: Int) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(radius).toFloat()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun matchWidth() = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
    private fun margin(top: Int = 0, bottom: Int = 0) = matchWidth().apply { topMargin = dp(top); bottomMargin = dp(bottom) }

    override fun onDestroy() {
        try { discoveryListener?.let { nsd.stopServiceDiscovery(it) } } catch (_: Exception) { }
        try { registrationListener?.let { nsd.unregisterService(it) } } catch (_: Exception) { }
        try { wifiLock.takeIf { it.isHeld }?.release() } catch (_: Exception) { }
        try { activeSocket?.close() } catch (_: Exception) { }
        try { serverSocket?.close() } catch (_: Exception) { }
        executor.shutdownNow()
        super.onDestroy()
    }
}
