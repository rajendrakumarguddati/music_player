package com.example.music_player

import android.content.ContentUris
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "music_scanner"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->

            if (call.method == "scanMusic") {
                try {
                    result.success(scanMusic())
                } catch (e: Exception) {
                    result.error(
                        "SCAN_ERROR",
                        e.message,
                        null
                    )
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun scanMusic(): List<Map<String, Any>> {

        val songs = mutableListOf<Map<String, Any>>()

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.RELATIVE_PATH
        )

        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI

        contentResolver.query(
            uri,
            projection,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            null,
            "${MediaStore.Audio.Media.TITLE} ASC"
        )?.use { cursor ->

            val idColumn =
                cursor.getColumnIndex(MediaStore.Audio.Media._ID)

            val titleColumn =
                cursor.getColumnIndex(MediaStore.Audio.Media.TITLE)

            val artistColumn =
                cursor.getColumnIndex(MediaStore.Audio.Media.ARTIST)

            val albumColumn =
                cursor.getColumnIndex(MediaStore.Audio.Media.ALBUM)

            val durationColumn =
                cursor.getColumnIndex(MediaStore.Audio.Media.DURATION)

            val displayNameColumn =
                cursor.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)

            val relativePathColumn =
                cursor.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)

            while (cursor.moveToNext()) {

                val displayName =
                    if (displayNameColumn >= 0) {
                        cursor.getString(displayNameColumn) ?: ""
                    } else {
                        ""
                    }

                val relativePath =
                    if (relativePathColumn >= 0) {
                        cursor.getString(relativePathColumn) ?: ""
                    } else {
                        ""
                    }

                // Ignore WhatsApp audio files
                val locationText =
                    "$displayName $relativePath".lowercase()

                if (
                    locationText.contains("whatsapp") ||
                    locationText.contains("com.whatsapp")
                ) {
                    continue
                }

                // Ignore call recordings
                if (
                    locationText.contains("call recording") ||
                    locationText.contains("call_recording") ||
                    locationText.contains("callrecording") ||
                    locationText.contains("recorded call") ||
                    locationText.contains("recorded_call") ||
                    locationText.contains("recording call")
                ) {
                    continue
                }

                val id = cursor.getLong(idColumn)

                val contentUri =
                    ContentUris.withAppendedId(uri, id)

                songs.add(
                    mapOf(
                        "id" to id,
                        "title" to (
                                cursor.getString(titleColumn)
                                    ?: displayName
                                ),
                        "artist" to (
                                cursor.getString(artistColumn)
                                    ?: "Unknown artist"
                                ),
                        "album" to (
                                cursor.getString(albumColumn)
                                    ?: "Unknown album"
                                ),
                        "duration" to cursor.getLong(durationColumn),
                        "uri" to contentUri.toString()
                    )
                )
            }
        }

        return songs
    }
}