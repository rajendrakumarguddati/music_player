package com.example.music_player_new

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.app.RecoverableSecurityException
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaMetadataRetriever
import android.media.audiofx.BassBoost
import android.media.audiofx.Virtualizer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val CHANNEL = "music_scanner"
    private val AUDIO_MIXER_CHANNEL = "audio_mixer"
    private val BLUETOOTH_CHANNEL = "bluetooth_devices"
    private val REQUEST_AUDIO_PERMISSION = 1001
    private val REQUEST_BLUETOOTH_PERMISSION = 1002
    private val REQUEST_DELETE_SONG = 1003

    private var pendingResult: MethodChannel.Result? = null
    private var pendingBluetoothDiscoveryResult: MethodChannel.Result? = null
    private var pendingBluetoothReadResult: MethodChannel.Result? = null
    private var pendingDeleteResult: MethodChannel.Result? = null

    // Media scanning/metadata extraction can be expensive. Keep it off the
    // Android UI thread so opening/returning to Home stays responsive.
    private val scanExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private val discoveredBluetoothDevices = linkedMapOf<String, BluetoothDevice>()
    private var bluetoothReceiverRegistered = false

    private val bluetoothReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                BluetoothDevice.ACTION_FOUND -> {
                    val device = getBluetoothDeviceFromIntent(intent) ?: return
                    val address = try { device.address } catch (_: SecurityException) { return }
                    discoveredBluetoothDevices[address] = device
                }

                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                    unregisterBluetoothReceiver()
                    val result = pendingBluetoothDiscoveryResult
                    pendingBluetoothDiscoveryResult = null
                    result?.success(getBluetoothDevices())
                }
            }
        }
    }

    // Native audio effects
    //
    // Equalizer is NOT created here.
    // The Equalizer is handled by just_audio's AndroidEqualizer
    // in main.dart and is attached directly to the AudioPlayer pipeline.
    private var bassBoost: BassBoost? = null
    private var virtualizer: Virtualizer? = null

    private var currentAudioSessionId: Int = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ---------------------------------------------------------
        // EXISTING MUSIC SCANNER CHANNEL
        // ---------------------------------------------------------
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "scanMusic" -> {
                    if (hasAudioPermission()) {
                        scanMusicAsync(result)
                    } else {
                        pendingResult = result
                        requestAudioPermission()
                    }
                }

                "enrichMusicMetadata" -> {
                    if (hasAudioPermission()) {
                        enrichMusicMetadataAsync(result)
                    } else {
                        result.success(emptyList<Map<String, Any?>>())
                    }
                }

                "deleteSong" -> {
                    val uriString = call.argument<String>("uri").orEmpty()
                    if (uriString.isBlank()) {
                        result.error("INVALID_URI", "Song URI is missing", null)
                    } else {
                        deleteSong(uriString, result)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }

        // ---------------------------------------------------------
        // BLUETOOTH DEVICES CHANNEL
        // ---------------------------------------------------------
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BLUETOOTH_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBluetoothDevices" -> {
                    if (hasBluetoothConnectPermission()) {
                        result.success(getBluetoothDevices())
                    } else {
                        pendingBluetoothReadResult = result
                        requestBluetoothPermissionsForRead()
                    }
                }

                "discoverBluetoothDevices" -> {
                    if (hasBluetoothPermissions()) {
                        startBluetoothDiscovery(result)
                    } else {
                        pendingBluetoothDiscoveryResult = result
                        requestBluetoothPermissions()
                    }
                }

                "pairBluetoothDevice" -> {
                    val address = call.argument<String>("address").orEmpty()
                    result.success(pairBluetoothDevice(address))
                }

                "getBluetoothState" -> {
                    result.success(getBluetoothAdapter()?.isEnabled == true)
                }

                "requestBluetoothEnable" -> {
                    requestBluetoothEnable(result)
                }

                "openBluetoothSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SETTINGS_ERROR", "Could not open Bluetooth settings", null)
                    }
                }

                else -> result.notImplemented()
            }
        }

        // ---------------------------------------------------------
        // NATIVE AUDIO MIXER CHANNEL
        // ---------------------------------------------------------
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AUDIO_MIXER_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                // Connect Mixer to the audio session used by just_audio.
                "setAudioSessionId" -> {

                    val sessionId =
                        (call.argument<Number>("sessionId"))?.toInt() ?: 0

                    if (sessionId <= 0) {

                        result.error(
                            "INVALID_SESSION",
                            "Invalid audio session ID",
                            null
                        )

                    } else {

                        result.success(
                            setAudioSessionId(sessionId)
                        )
                    }
                }

                // Test method.
                "testMixer" -> {
                    result.success("Mixer channel connected")
                }

                // Equalizer ON/OFF.
                //
                // The actual Equalizer is controlled by
                // AndroidEqualizer in main.dart.
                "setEqualizerEnabled" -> {

                    val enabled =
                        call.argument<Boolean>("enabled") ?: false

                    result.success(
                        setEqualizerEnabled(enabled)
                    )
                }

                // Set one Equalizer band.
                //
                // Kept for compatibility with the existing
                // MethodChannel. The actual band control is done
                // by AndroidEqualizer in main.dart.
                "setEqualizerBand" -> {

                    val band =
                        (call.argument<Number>("band"))?.toInt() ?: -1

                    val level =
                        (call.argument<Number>("level"))?.toInt() ?: 0

                    result.success(
                        setEqualizerBand(band, level)
                    )
                }

                // Bass Boost.
                //
                // strength:
                // 0    = 0%
                // 1000 = 100%
                "setBassBoost" -> {

                    val strength =
                        ((call.argument<Number>("strength"))?.toInt() ?: 0)
                            .coerceIn(0, 1000)

                    val enabled =
                        call.argument<Boolean>("enabled")
                            ?: (strength > 0)

                    result.success(
                        setBassBoost(strength, enabled)
                    )
                }

                // Virtualizer.
                //
                // strength:
                // 0    = 0%
                // 1000 = 100%
                "setVirtualizer" -> {

                    val strength =
                        ((call.argument<Number>("strength"))?.toInt() ?: 0)
                            .coerceIn(0, 1000)

                    val enabled =
                        call.argument<Boolean>("enabled")
                            ?: (strength > 0)

                    result.success(
                        setVirtualizer(strength, enabled)
                    )
                }

                // Return information about Equalizer.
                //
                // This reports the just_audio EQ configuration
                // expected by the existing Dart mixer.
                "getEqualizerInfo" -> {

                    result.success(
                        getEqualizerInfo()
                    )
                }

                // Release BassBoost and Virtualizer.
                //
                // AndroidEqualizer belongs to just_audio's
                // AudioPipeline and is therefore not released here.
                "releaseAudioEffects" -> {

                    releaseAudioEffects()

                    result.success(null)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    // =============================================================
    // BLUETOOTH DEVICES
    // =============================================================

    private fun hasBluetoothConnectPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    private fun hasBluetoothScanPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
        } else {
            checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun hasBluetoothPermissions(): Boolean {
        return hasBluetoothConnectPermission() && hasBluetoothScanPermission()
    }

    private fun requestBluetoothPermissionsForRead() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            requestPermissions(
                arrayOf(Manifest.permission.BLUETOOTH_CONNECT),
                REQUEST_BLUETOOTH_PERMISSION
            )
        } else {
            pendingBluetoothReadResult?.error(
                "BLUETOOTH_PERMISSION",
                "Bluetooth permission is required",
                null
            )
            pendingBluetoothReadResult = null
        }
    }

    private fun requestBluetoothPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            requestPermissions(
                arrayOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT
                ),
                REQUEST_BLUETOOTH_PERMISSION
            )
        } else {
            requestPermissions(
                arrayOf(Manifest.permission.ACCESS_FINE_LOCATION),
                REQUEST_BLUETOOTH_PERMISSION
            )
        }
    }

    private fun getBluetoothAdapter(): BluetoothAdapter? {
        val manager = getSystemService(BLUETOOTH_SERVICE) as? BluetoothManager
        return manager?.adapter
    }

    private fun getBluetoothDeviceFromIntent(intent: Intent): BluetoothDevice? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun requestBluetoothEnable(result: MethodChannel.Result) {
        val adapter = getBluetoothAdapter()
        if (adapter == null) {
            result.error(
                "BLUETOOTH_UNAVAILABLE",
                "Bluetooth is not available on this device",
                null
            )
            return
        }

        if (adapter.isEnabled) {
            result.success(true)
            return
        }

        try {
            // Modern Android does not allow normal apps to silently toggle Bluetooth.
            // Ask the system to enable it instead.
            startActivity(
                Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
            )
            result.success(false)
        } catch (e: Exception) {
            result.error(
                "BLUETOOTH_ENABLE_ERROR",
                "Could not open the Bluetooth enable prompt",
                null
            )
        }
    }

    private fun startBluetoothDiscovery(result: MethodChannel.Result) {
        val adapter = getBluetoothAdapter()
        if (adapter == null) {
            result.error("BLUETOOTH_UNAVAILABLE", "Bluetooth is not available on this device", null)
            return
        }

        if (!adapter.isEnabled) {
            requestBluetoothEnable(result)
            return
        }

        if (!hasBluetoothPermissions()) {
            pendingBluetoothDiscoveryResult = result
            requestBluetoothPermissions()
            return
        }

        try {
            if (adapter.isDiscovering) {
                adapter.cancelDiscovery()
            }

            discoveredBluetoothDevices.clear()

            registerBluetoothReceiver()
            pendingBluetoothDiscoveryResult = result

            if (!adapter.startDiscovery()) {
                unregisterBluetoothReceiver()
                pendingBluetoothDiscoveryResult = null
                result.error("DISCOVERY_FAILED", "Bluetooth discovery could not be started", null)
            }
        } catch (e: SecurityException) {
            unregisterBluetoothReceiver()
            pendingBluetoothDiscoveryResult = null
            result.error("BLUETOOTH_PERMISSION", "Bluetooth permission is required", null)
        } catch (e: Exception) {
            unregisterBluetoothReceiver()
            pendingBluetoothDiscoveryResult = null
            result.error("DISCOVERY_FAILED", e.message, null)
        }
    }

    private fun registerBluetoothReceiver() {
        if (bluetoothReceiverRegistered) return

        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(bluetoothReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(bluetoothReceiver, filter)
        }

        bluetoothReceiverRegistered = true
    }

    private fun unregisterBluetoothReceiver() {
        if (!bluetoothReceiverRegistered) return
        try {
            unregisterReceiver(bluetoothReceiver)
        } catch (_: Exception) {
        }
        bluetoothReceiverRegistered = false
    }

    private fun getConnectedAudioNames(): Set<String> {
        val names = mutableSetOf<String>()
        try {
            val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
            val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            for (output in outputs) {
                val isBluetoothAudio = output.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                        output.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                                output.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
                if (isBluetoothAudio) {
                    val name = output.productName?.toString()?.trim().orEmpty()
                    if (name.isNotEmpty()) names.add(name)
                }
            }
        } catch (e: Exception) {
            Log.w("MusicPlayer", "Could not read connected Bluetooth audio devices", e)
        }
        return names
    }

    // On Android 12+, AudioDeviceInfo can expose the Bluetooth audio route
    // address. Matching by address is more reliable than matching display
    // names, especially when the user renames a Bluetooth device (for example
    // Rockerz 412 -> BEAST).
    private fun getConnectedAudioAddresses(): Set<String> {
        val addresses = mutableSetOf<String>()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return addresses

        try {
            val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
            val outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            for (output in outputs) {
                val isBluetoothAudio = output.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                        output.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        output.type == AudioDeviceInfo.TYPE_BLE_HEADSET
                if (isBluetoothAudio) {
                    val address = output.address?.trim().orEmpty()
                    if (address.isNotEmpty()) addresses.add(address)
                }
            }
        } catch (e: Exception) {
            Log.w("MusicPlayer", "Could not read connected Bluetooth audio addresses", e)
        }
        return addresses
    }

    private fun readBluetoothBattery(device: BluetoothDevice): Int? {
        if (!hasBluetoothConnectPermission()) return null
        return try {
            // Some Android/device combinations expose getBatteryLevel while others do not.
            // Reflection keeps the feature optional and avoids breaking unsupported devices.
            val method = device.javaClass.getMethod("getBatteryLevel")
            val value = method.invoke(device) as? Int ?: return null
            if (value in 0..100) value else null
        } catch (_: Exception) {
            null
        }
    }

    private fun bluetoothDeviceType(device: BluetoothDevice): String {
        val name = try { device.name.orEmpty().lowercase() } catch (_: Exception) { "" }
        return when {
            name.contains("car") || name.contains("auto") || name.contains("vehicle") -> "car"
            name.contains("speaker") || name.contains("soundbar") || name.contains("flip") -> "speaker"
            else -> "headphones"
        }
    }

    private fun bluetoothMap(
        device: BluetoothDevice,
        connected: Boolean,
        paired: Boolean
    ): Map<String, Any?> {
        val name = try { device.name?.trim().takeUnless { it.isNullOrEmpty() } ?: "Unknown device" }
        catch (_: Exception) { "Unknown device" }

        val address = try { device.address } catch (_: Exception) { "" }

        return mapOf(
            "name" to name,
            "address" to address,
            "connected" to connected,
            "paired" to paired,
            "battery" to readBluetoothBattery(device),
            "type" to bluetoothDeviceType(device)
        )
    }

    private fun getBluetoothDevices(): List<Map<String, Any?>> {
        val adapter = getBluetoothAdapter() ?: return emptyList()
        if (!adapter.isEnabled) return emptyList()
        if (!hasBluetoothConnectPermission()) return emptyList()

        val connectedNames = getConnectedAudioNames()
        val connectedAddresses = getConnectedAudioAddresses()
        val devices = linkedMapOf<String, Map<String, Any?>>()

        try {
            for (device in adapter.bondedDevices) {
                val name = try { device.name?.trim().orEmpty() } catch (_: Exception) { "" }
                val address = try { device.address } catch (_: Exception) { continue }
                val connectedByAddress = connectedAddresses.any {
                    it.equals(address, ignoreCase = true)
                }
                val connectedByName = name.isNotEmpty() && connectedNames.any {
                    it.equals(name, ignoreCase = true)
                }
                val connected = connectedByAddress || connectedByName
                devices[address] = bluetoothMap(device, connected, true)
            }
        } catch (e: SecurityException) {
            return emptyList()
        }

        // Add nearby devices found by the most recent discovery.
        for ((address, device) in discoveredBluetoothDevices) {
            if (devices.containsKey(address)) continue
            val name = try { device.name?.trim().orEmpty() } catch (_: Exception) { "" }
            if (name.isNotEmpty()) {
                devices[address] = bluetoothMap(device, false, false)
            }
        }

        // A connected audio route may not be present in bondedDevices on some devices.
        for (name in connectedNames) {
            val alreadyPresent = devices.values.any {
                (it["name"]?.toString() ?: "").equals(name, ignoreCase = true)
            }
            if (!alreadyPresent) {
                devices["connected:$name"] = mapOf(
                    "name" to name,
                    "address" to "",
                    "connected" to true,
                    "paired" to false,
                    "battery" to null,
                    "type" to "headphones"
                )
            }
        }

        return devices.values.sortedWith(
            compareByDescending<Map<String, Any?>> { it["connected"] == true }
                .thenByDescending { it["paired"] == true }
                .thenBy { it["name"]?.toString()?.lowercase() ?: "" }
        )
    }

    private fun pairBluetoothDevice(address: String): Boolean {
        if (address.isBlank()) return false
        if (!hasBluetoothConnectPermission()) return false

        return try {
            val adapter = getBluetoothAdapter() ?: return false
            val device = adapter.getRemoteDevice(address)
            device.createBond()
        } catch (e: Exception) {
            Log.w("MusicPlayer", "Could not pair Bluetooth device", e)
            false
        }
    }

    // =============================================================
    // AUDIO SESSION / EFFECT SETUP
    // =============================================================

    private fun setAudioSessionId(
        sessionId: Int
    ): Map<String, Any> {

        // Release BassBoost and Virtualizer belonging to
        // the old audio session.
        releaseAudioEffects()

        currentAudioSessionId = sessionId

        var equalizerAvailable = false
        var bassBoostAvailable = false
        var virtualizerAvailable = false

        // ---------------------------------------------------------
        // EQUALIZER
        // ---------------------------------------------------------
        //
        // IMPORTANT:
        //
        // The actual Equalizer is owned by just_audio's
        // AndroidEqualizer in main.dart.
        //
        // main.dart attaches it directly to:
        //
        // AudioPlayer
        //      ↓
        // AudioPipeline
        //      ↓
        // AndroidEqualizer
        //
        // Therefore we MUST NOT create another native Android
        // Equalizer here.
        //
        equalizerAvailable = true

        // ---------------------------------------------------------
        // BASS BOOST
        // ---------------------------------------------------------
        try {

            bassBoost = BassBoost(1000, sessionId).apply {

                setStrength(0)

                enabled = false
            }

            bassBoostAvailable = true

        } catch (e: Exception) {

            Log.w(
                "MusicPlayer",
                "BassBoost unavailable",
                e
            )

            bassBoost = null
        }

        // ---------------------------------------------------------
        // VIRTUALIZER
        // ---------------------------------------------------------
        try {

            virtualizer = Virtualizer(1000, sessionId).apply {

                setStrength(0)

                enabled = false
            }

            virtualizerAvailable = true

        } catch (e: Exception) {

            Log.w(
                "MusicPlayer",
                "Virtualizer unavailable",
                e
            )

            virtualizer = null
        }

        return mapOf(
            "equalizer" to equalizerAvailable,
            "bassBoost" to bassBoostAvailable,
            "virtualizer" to virtualizerAvailable
        )
    }

    // =============================================================
    // EQUALIZER
    // =============================================================
    //
    // The real Equalizer is controlled by just_audio's
    // AndroidEqualizer in main.dart.
    //
    // These functions remain only for compatibility with the
    // existing MethodChannel.
    //
    // They intentionally DO NOT create or control another
    // native Android Equalizer.
    // =============================================================

    private fun setEqualizerEnabled(
        enabled: Boolean
    ): Boolean {

        // AndroidEqualizer is controlled from main.dart.
        return true
    }

    private fun setEqualizerBand(
        band: Int,
        requestedLevel: Int
    ): Boolean {

        // AndroidEqualizer is controlled from main.dart.
        //
        // The current Dart mixer has 7 bands.
        return band in 0..6
    }

    private fun getEqualizerInfo(): Map<String, Any> {

        return mapOf(
            "available" to true,
            "bands" to 7,
            "minLevel" to -1200,
            "maxLevel" to 1200
        )
    }

    // =============================================================
    // BASS BOOST
    // =============================================================

    private fun setBassBoost(
        strength: Int,
        enabled: Boolean
    ): Boolean {

        val effect = bassBoost ?: return false

        return try {
            val safeStrength = strength.coerceIn(0, 1000)

            effect.setStrength(safeStrength.toShort())
            effect.enabled = enabled && safeStrength > 0

            Log.d(
                "MusicPlayer",
                "BassBoost strength=$safeStrength enabled=${effect.enabled} " +
                        "supported=${effect.strengthSupported} actual=${effect.roundedStrength}"
            )

            true
        } catch (e: Exception) {
            Log.w(
                "MusicPlayer",
                "Could not update BassBoost",
                e
            )

            false
        }
    }

    // =============================================================
    // VIRTUALIZER
    // =============================================================

    private fun setVirtualizer(
        strength: Int,
        enabled: Boolean
    ): Boolean {

        val effect = virtualizer ?: return false

        return try {
            val safeStrength = strength.coerceIn(0, 1000)

            effect.setStrength(safeStrength.toShort())
            effect.enabled = enabled && safeStrength > 0

            Log.d(
                "MusicPlayer",
                "Virtualizer strength=$safeStrength enabled=${effect.enabled} " +
                        "supported=${effect.strengthSupported} actual=${effect.roundedStrength}"
            )

            true
        } catch (e: Exception) {
            Log.w(
                "MusicPlayer",
                "Could not update Virtualizer",
                e
            )

            false
        }
    }

    // =============================================================
    // RELEASE AUDIO EFFECTS
    // =============================================================

    private fun releaseAudioEffects() {

        // Do NOT release the Equalizer here.
        //
        // The Equalizer belongs to just_audio's AudioPipeline.

        try {

            bassBoost?.release()

        } catch (_: Exception) {
        }

        try {

            virtualizer?.release()

        } catch (_: Exception) {
        }

        bassBoost = null
        virtualizer = null

        currentAudioSessionId = 0
    }

    // =============================================================
    // PERMISSIONS
    // =============================================================

    private fun hasAudioPermission(): Boolean {

        return if (
            Build.VERSION.SDK_INT >=
            Build.VERSION_CODES.TIRAMISU
        ) {

            checkSelfPermission(
                Manifest.permission.READ_MEDIA_AUDIO
            ) == PackageManager.PERMISSION_GRANTED

        } else {

            checkSelfPermission(
                Manifest.permission.READ_EXTERNAL_STORAGE
            ) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestAudioPermission() {

        if (
            Build.VERSION.SDK_INT >=
            Build.VERSION_CODES.TIRAMISU
        ) {

            requestPermissions(
                arrayOf(
                    Manifest.permission.READ_MEDIA_AUDIO
                ),
                REQUEST_AUDIO_PERMISSION
            )

        } else {

            requestPermissions(
                arrayOf(
                    Manifest.permission.READ_EXTERNAL_STORAGE
                ),
                REQUEST_AUDIO_PERMISSION
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {

        super.onRequestPermissionsResult(
            requestCode,
            permissions,
            grantResults
        )

        if (requestCode == REQUEST_BLUETOOTH_PERMISSION) {
            val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            } else {
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            }

            if (granted) {
                val discoveryResult = pendingBluetoothDiscoveryResult
                pendingBluetoothDiscoveryResult = null
                if (discoveryResult != null) {
                    startBluetoothDiscovery(discoveryResult)
                } else {
                    pendingBluetoothReadResult?.success(getBluetoothDevices())
                    pendingBluetoothReadResult = null
                }
            } else {
                pendingBluetoothDiscoveryResult?.error(
                    "BLUETOOTH_PERMISSION",
                    "Bluetooth permission was denied",
                    null
                )
                pendingBluetoothDiscoveryResult = null
                pendingBluetoothReadResult?.error(
                    "BLUETOOTH_PERMISSION",
                    "Bluetooth permission was denied",
                    null
                )
                pendingBluetoothReadResult = null
            }
        }

        if (requestCode == REQUEST_AUDIO_PERMISSION) {

            if (
                grantResults.isNotEmpty() &&
                grantResults[0] ==
                PackageManager.PERMISSION_GRANTED
            ) {

                val scanResult = pendingResult
                pendingResult = null
                if (scanResult != null) {
                    scanMusicAsync(scanResult)
                }

            } else {

                pendingResult?.error(
                    "PERMISSION_DENIED",
                    "Music permission was denied",
                    null
                )
            }

            pendingResult = null
        }
    }

    // =============================================================
    // DELETE SONG
    // =============================================================
    //
    // Deletes the selected MediaStore audio item. On newer Android
    // versions Android may require the user to confirm the deletion.
    // =============================================================

    private fun deleteSong(
        uriString: String,
        result: MethodChannel.Result
    ) {
        val uri = try {
            android.net.Uri.parse(uriString)
        } catch (e: Exception) {
            result.error("INVALID_URI", "Invalid song URI", null)
            return
        }

        if (uri.scheme != "content") {
            result.error(
                "INVALID_URI",
                "Only MediaStore content URIs can be deleted",
                null
            )
            return
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val request = MediaStore.createDeleteRequest(
                    contentResolver,
                    listOf(uri)
                )

                pendingDeleteResult = result

                try {
                    startIntentSenderForResult(
                        request.intentSender,
                        REQUEST_DELETE_SONG,
                        null,
                        0,
                        0,
                        0
                    )
                } catch (e: Exception) {
                    pendingDeleteResult = null
                    result.error(
                        "DELETE_CONFIRMATION_ERROR",
                        "Could not open Android deletion confirmation",
                        e.message
                    )
                }
                return
            }

            if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
                try {
                    val deleted = contentResolver.delete(uri, null, null) > 0
                    result.success(deleted)
                } catch (e: RecoverableSecurityException) {
                    pendingDeleteResult = result
                    try {
                        startIntentSenderForResult(
                            e.userAction.actionIntent.intentSender,
                            REQUEST_DELETE_SONG,
                            null,
                            0,
                            0,
                            0
                        )
                    } catch (launchError: Exception) {
                        pendingDeleteResult = null
                        result.error(
                            "DELETE_CONFIRMATION_ERROR",
                            "Could not open Android deletion confirmation",
                            launchError.message
                        )
                    }
                }
                return
            }

            result.success(contentResolver.delete(uri, null, null) > 0)
        } catch (e: SecurityException) {
            result.error(
                "DELETE_PERMISSION",
                "Android did not allow this song to be deleted",
                e.message
            )
        } catch (e: Exception) {
            result.error(
                "DELETE_FAILED",
                "Could not delete this song",
                e.message
            )
        }
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQUEST_DELETE_SONG) {
            val result = pendingDeleteResult
            pendingDeleteResult = null

            if (result != null) {
                result.success(resultCode == RESULT_OK)
            }
        }
    }

    // =============================================================
    // EMBEDDED GENRE + ALBUM ARTWORK
    // =============================================================

    private data class MediaMetadataResult(
        val genre: String,
        val artworkPath: String
    )

    // Read genre and embedded artwork with ONE MediaMetadataRetriever per song.
    // The previous implementation opened a retriever once for genre and again
    // for artwork, which made library scans unnecessarily expensive.
    private fun extractMediaMetadata(
        path: String,
        id: Long
    ): MediaMetadataResult {
        if (path.isBlank()) {
            return MediaMetadataResult("", "")
        }

        val artworkDirectory = File(cacheDir, "album_art")
        if (!artworkDirectory.exists()) {
            artworkDirectory.mkdirs()
        }

        val artworkFile = File(artworkDirectory, "$id.jpg")
        var genre = ""

        try {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(path)

                genre = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_GENRE)
                    ?.trim()
                    .orEmpty()

                if (genre.isBlank() || genre.equals("<unknown>", ignoreCase = true)) {
                    genre = ""
                }

                // Do not decode/write album art again when it is already cached.
                if (!artworkFile.exists() || artworkFile.length() <= 0) {
                    val artwork = retriever.embeddedPicture
                    if (artwork != null && artwork.isNotEmpty()) {
                        artworkFile.writeBytes(artwork)
                    }
                }
            } finally {
                retriever.release()
            }
        } catch (e: Exception) {
            Log.w("MusicPlayer", "Could not extract media metadata", e)
        }

        return MediaMetadataResult(
            genre = genre,
            artworkPath = if (artworkFile.exists() && artworkFile.length() > 0) {
                artworkFile.absolutePath
            } else {
                ""
            }
        )
    }

    // =============================================================
    // MUSIC SCANNER
    // =============================================================

    private fun enrichMusicMetadataAsync(result: MethodChannel.Result) {
        scanExecutor.execute {
            try {
                val metadata = enrichMusicMetadata()
                mainHandler.post {
                    result.success(metadata)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        "METADATA_ERROR",
                        e.message ?: "Could not enrich music metadata",
                        null
                    )
                }
            }
        }
    }

    private fun enrichMusicMetadata(): List<Map<String, Any?>> {
        val metadata = mutableListOf<Map<String, Any?>>()
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DATA
        )
        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"

        contentResolver.query(
            collection,
            projection,
            selection,
            null,
            null
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val dataColumn = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                val path = if (dataColumn >= 0) cursor.getString(dataColumn).orEmpty() else ""
                if (path.isBlank()) continue

                val mediaMetadata = extractMediaMetadata(path, id)
                metadata.add(
                    mapOf(
                        "id" to id,
                        "genre" to mediaMetadata.genre,
                        "artworkPath" to mediaMetadata.artworkPath
                    )
                )
            }
        }

        return metadata
    }

    private fun scanMusicAsync(result: MethodChannel.Result) {
        scanExecutor.execute {
            try {
                val songs = scanMusic()
                mainHandler.post {
                    result.success(songs)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error(
                        "SCAN_ERROR",
                        e.message ?: "Could not scan music",
                        null
                    )
                }
            }
        }
    }

    private fun scanMusic(): List<Map<String, Any?>> {

        val songs =
            mutableListOf<Map<String, Any?>>()

        val collection =
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI

        val projection =
            arrayOf(
                MediaStore.Audio.Media._ID,
                MediaStore.Audio.Media.TITLE,
                MediaStore.Audio.Media.ARTIST,
                MediaStore.Audio.Media.ALBUM,
                MediaStore.Audio.Media.DURATION,
                MediaStore.Audio.Media.DISPLAY_NAME,
                MediaStore.Audio.Media.MIME_TYPE,
                MediaStore.Audio.Media.DATA,
                MediaStore.Audio.Media.IS_MUSIC
            )

        val selection =
            "${MediaStore.Audio.Media.IS_MUSIC} != 0"

        val sortOrder =
            "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC"

        // Reuse this list for every row instead of allocating it repeatedly.
        val blockedWords = listOf(
            "whatsapp",
            "call recording",
            "call_recording",
            "callrecording",
            "recordings",
            "recording",
            "voice recorder",
            "voice_recorder",
            "voicerecorder",
            "telegram",
            "ringtones",
            "alarms",
            "notifications",
            "notification",
            "screenrecord",
            "screen_record"
        )

        contentResolver.query(
            collection,
            projection,
            selection,
            null,
            sortOrder
        )?.use { cursor ->

            val idColumn =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Audio.Media._ID
                )

            val titleColumn =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Audio.Media.TITLE
                )

            val artistColumn =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Audio.Media.ARTIST
                )

            val albumColumn =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Audio.Media.ALBUM
                )

            val durationColumn =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Audio.Media.DURATION
                )

            val displayNameColumn =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Audio.Media.DISPLAY_NAME
                )

            val mimeColumn =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Audio.Media.MIME_TYPE
                )

            val dataColumn =
                cursor.getColumnIndex(
                    MediaStore.Audio.Media.DATA
                )

            while (cursor.moveToNext()) {

                val id =
                    cursor.getLong(idColumn)

                val title =
                    cursor.getString(titleColumn)
                        ?.trim()
                        .orEmpty()

                val artist =
                    cursor.getString(artistColumn)
                        ?.trim()
                        .orEmpty()

                val album =
                    cursor.getString(albumColumn)
                        ?.trim()
                        .orEmpty()

                val duration =
                    cursor.getLong(durationColumn)

                val displayName =
                    cursor.getString(displayNameColumn)
                        ?.trim()
                        .orEmpty()

                val mimeType =
                    cursor.getString(mimeColumn)
                        ?.trim()
                        .orEmpty()

                val path =
                    if (dataColumn >= 0) {

                        cursor.getString(dataColumn)
                            ?.trim()
                            .orEmpty()

                    } else {
                        ""
                    }

                val searchableText =
                    (
                            "$title " +
                                    "$artist " +
                                    "$album " +
                                    "$displayName " +
                                    "$path"
                            ).lowercase()

                // Ignore recordings and non-music folders/files.
                val isBlocked =
                    blockedWords.any {
                        searchableText.contains(it)
                    }

                if (isBlocked) {
                    continue
                }

                // Ignore extremely short/invalid entries.
                if (
                    title.isBlank() &&
                    displayName.isBlank()
                ) {
                    continue
                }

                if (duration <= 0) {
                    continue
                }

                val contentUri =
                    ContentUris.withAppendedId(
                        collection,
                        id
                    )

                // Keep the initial scan strictly MediaStore-only. Genre and
                // embedded artwork are extracted in a second background pass,
                // so Home can receive the song list without waiting for one
                // MediaMetadataRetriever per track.
                val artworkDirectory = File(cacheDir, "album_art")
                val artworkFile = File(artworkDirectory, "$id.jpg")
                val genre = ""
                val artworkPath = if (artworkFile.exists() && artworkFile.length() > 0) {
                    artworkFile.absolutePath
                } else {
                    ""
                }

                songs.add(
                    mapOf(

                        "id" to id,

                        "title" to if (
                            title.isNotBlank()
                        ) {
                            title
                        } else {
                            displayName
                        },

                        "artist" to if (
                            artist.isNotBlank() &&
                            artist != "<unknown>"
                        ) {
                            artist
                        } else {
                            "Unknown Artist"
                        },

                        "album" to if (
                            album.isNotBlank() &&
                            album != "<unknown>"
                        ) {
                            album
                        } else {
                            "Unknown Album"
                        },

                        "genre" to genre,

                        "duration" to duration,

                        "displayName" to displayName,

                        "mimeType" to mimeType,

                        "path" to path,

                        "uri" to contentUri.toString(),

                        // Real embedded album artwork.
                        "artworkPath" to artworkPath
                    )
                )
            }
        }

        return songs
    }

    // =============================================================
    // CLEANUP
    // =============================================================

    override fun onDestroy() {

        unregisterBluetoothReceiver()
        pendingBluetoothDiscoveryResult = null
        pendingBluetoothReadResult = null
        pendingDeleteResult = null
        scanExecutor.shutdownNow()
        releaseAudioEffects()

        super.onDestroy()
    }
}