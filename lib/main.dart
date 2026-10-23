import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MusicPlayerApp());
}

// =====================================================
// MUSIC SCANNER CHANNEL
// =====================================================

const MethodChannel _musicChannel =
MethodChannel('music_scanner');

const MethodChannel _audioMixerChannel =
MethodChannel('audio_mixer');

const MethodChannel _bluetoothChannel =
MethodChannel('bluetooth_devices');

Future<List<Map<String, dynamic>>> _getBluetoothDevices() async {
  final result = await _bluetoothChannel.invokeMethod<List<dynamic>>('getBluetoothDevices');
  return (result ?? <dynamic>[])
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList();
}

// Use just_audio's built-in Android equalizer so the EQ is attached directly
// to this AudioPlayer's audio pipeline. No extra package is required.
final AndroidEqualizer _androidEqualizer = AndroidEqualizer();
const List<double> _mixerFrequenciesHz = [60, 150, 400, 1000, 2400, 6000, 14000];

Future<void> _syncAudioSession(AudioPlayer player) async {
  final sessionId = player.androidAudioSessionId;
  if (sessionId == null || sessionId <= 0) return;
  try {
    await _audioMixerChannel.invokeMethod('setAudioSessionId', {'sessionId': sessionId});
    await _applySavedMixerSettingsToPlayer();
  } catch (e) {
    debugPrint('AUDIO MIXER SESSION ERROR: $e');
  }
}

// Apply the saved mixer settings to the actual player as soon as its
// Android audio session is ready. This keeps the Mixer screen from being
// required just to activate the saved EQ/Bass Boost/Virtualizer settings.
Future<void> _applySavedMixerSettingsToPlayer() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final savedBands = prefs.getStringList('mixer_eq_bands');
    var bands = List<double>.filled(7, 0);
    if (savedBands != null && savedBands.length == 7) {
      final parsed = savedBands.map((value) => double.tryParse(value)).toList();
      if (parsed.every((value) => value != null)) {
        bands = parsed.cast<double>();
      }
    }

    final bassBoost =
    (prefs.getDouble('mixer_bass_boost') ?? 0).clamp(0, 100).toDouble();
    final virtualizer =
    (prefs.getDouble('mixer_virtualizer') ?? 0).clamp(0, 100).toDouble();

    await _androidEqualizer.setEnabled(true);
    final parameters = await _androidEqualizer.parameters;

    if (parameters.bands.isNotEmpty) {
      const virtualizerCurve = <double>[
        0.5, 0.0, -0.8, -1.2, 0.8, 1.8, 2.2,
      ];

      for (var i = 0; i < bands.length; i++) {
        final targetFrequency = _mixerFrequenciesHz[i];
        final nativeBand = parameters.bands.reduce(
              (a, b) =>
          (a.centerFrequency - targetFrequency).abs() <=
              (b.centerFrequency - targetFrequency).abs()
              ? a
              : b,
        );

        var effectiveValue = bands[i];
        if (i == 0) {
          effectiveValue += bassBoost * 0.08;
        } else if (i == 1) {
          effectiveValue += bassBoost * 0.05;
        } else if (i == 2) {
          effectiveValue += bassBoost * 0.02;
        }
        effectiveValue += virtualizerCurve[i] * (virtualizer / 100.0);

        final gain = effectiveValue
            .clamp(parameters.minDecibels, parameters.maxDecibels)
            .toDouble();
        await nativeBand.setGain(gain);
      }
    }

    await _audioMixerChannel.invokeMethod('setBassBoost', {
      'strength': (bassBoost * 10).round(),
      'enabled': bassBoost > 0,
    });
    await _audioMixerChannel.invokeMethod('setVirtualizer', {
      'strength': (virtualizer * 10).round(),
      'enabled': virtualizer > 0,
    });
  } catch (e) {
    debugPrint('SAVED MIXER APPLY ERROR: $e');
  }
}

// =====================================================
// FAVOURITES STORAGE
// =====================================================

class FavoriteStore {
  static const String _key = 'favorite_song_uris';

  static Future<Set<String>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? <String>[]).toSet();
  }

  static Future<bool> isFavourite(String uri) async {
    if (uri.isEmpty) return false;
    final favourites = await getAll();
    return favourites.contains(uri);
  }

  static Future<void> setFavourite(String uri, bool favourite) async {
    if (uri.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final favourites = (prefs.getStringList(_key) ?? <String>[]).toSet();
    if (favourite) {
      favourites.add(uri);
    } else {
      favourites.remove(uri);
    }
    await prefs.setStringList(_key, favourites.toList());
  }
}


// =====================================================
// PLAYLIST STORAGE
// =====================================================

class PlaylistStore {
  static const String _key = 'music_playlists_v1';

  static Future<Map<String, List<String>>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};

      final result = <String, List<String>>{};
      decoded.forEach((key, value) {
        if (key is String && value is List) {
          result[key] = value
              .whereType<String>()
              .where((uri) => uri.isNotEmpty)
              .toList();
        }
      });
      return result;
    } catch (e) {
      debugPrint('PLAYLIST LOAD ERROR: $e');
      return {};
    }
  }

  static Future<void> _save(Map<String, List<String>> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(playlists));
  }

  static Future<bool> create(String name) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return false;

    final playlists = await getAll();
    if (playlists.keys.any((key) => key.toLowerCase() == cleanName.toLowerCase())) {
      return false;
    }

    playlists[cleanName] = [];
    await _save(playlists);
    return true;
  }

  static Future<void> delete(String name) async {
    final playlists = await getAll();
    playlists.remove(name);
    await _save(playlists);
  }

  static Future<bool> rename(String oldName, String newName) async {
    final cleanName = newName.trim();
    if (cleanName.isEmpty || oldName == cleanName) return false;

    final playlists = await getAll();
    if (!playlists.containsKey(oldName)) return false;

    final duplicate = playlists.keys.any(
          (key) => key != oldName && key.toLowerCase() == cleanName.toLowerCase(),
    );
    if (duplicate) return false;

    final songs = playlists.remove(oldName) ?? <String>[];
    playlists[cleanName] = songs;
    await _save(playlists);
    return true;
  }

  static Future<void> addSongs(String name, List<String> uris) async {
    final playlists = await getAll();
    final current = playlists[name] ?? <String>[];

    for (final uri in uris) {
      if (uri.isNotEmpty && !current.contains(uri)) {
        current.add(uri);
      }
    }

    playlists[name] = current;
    await _save(playlists);
  }

  static Future<void> removeSong(String name, String uri) async {
    final playlists = await getAll();
    final current = playlists[name];
    if (current == null) return;

    current.remove(uri);
    playlists[name] = current;
    await _save(playlists);
  }

  static Future<void> reorderSongs(String name, List<String> uris) async {
    final playlists = await getAll();
    if (!playlists.containsKey(name)) return;

    playlists[name] = List<String>.from(uris);
    await _save(playlists);
  }
}


// =====================================================
// APP
// =====================================================

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Music Player',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          surface: Colors.black,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// =====================================================
// HOME PAGE
// =====================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final AudioPlayer _audioPlayer = AudioPlayer(
    audioPipeline: AudioPipeline(
      androidAudioEffects: [_androidEqualizer],
    ),
  );

  late Future<List<Map<String, dynamic>>> _songsFuture;

  String _currentTitle = '';
  String _currentArtist = '';
  String _currentUri = '';
  String _currentArtworkPath = '';

  final ValueNotifier<MiniPlayerData?> _miniPlayerData =
  ValueNotifier<MiniPlayerData?>(null);

  // Persist the current song and playback position so the player can
  // restore the same song/time after the app is closed and reopened.
  static const String _lastPlayedUriKey = 'last_played_song_uri';
  static const String _lastPlayedPositionKey = 'last_played_song_position_ms';
  static const String _songsCacheKey = 'rajune_songs_cache_v2';
  Duration _lastKnownPosition = Duration.zero;
  Timer? _playbackSaveTimer;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<bool>? _playingSubscription;
  bool _restoringLastPlayback = false;
  Future<void>? _restoreFuture;

  int _currentSongIndex = -1;

// Queue stores song indexes from the scanned music list.
  final List<int> _queueIndices = [];
  int _queuePosition = -1;

  String _connectedBluetoothName = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _songsFuture = _loadSongs();

    // Keep the latest position in memory and persist it periodically.
    _positionSubscription = _audioPlayer.positionStream.listen((position) {
      _lastKnownPosition = position;
    });

    _playingSubscription = _audioPlayer.playingStream.listen((playing) {
      if (!playing && _currentUri.isNotEmpty) {
        _saveLastPlayback();
      }
    });

    _playbackSaveTimer = Timer.periodic(
      const Duration(seconds: 2),
          (_) {
        if (_audioPlayer.playing && _currentUri.isNotEmpty) {
          _saveLastPlayback();
        }
      },
    );

    _restoreFuture = _restoreLastPlayback();
    _loadBluetoothStatus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveLastPlayback();
    }
  }

  @override
  void dispose() {
    _saveLastPlayback();
    WidgetsBinding.instance.removeObserver(this);
    _playbackSaveTimer?.cancel();
    _positionSubscription?.cancel();
    _playingSubscription?.cancel();
    _audioPlayer.dispose();
    _miniPlayerData.dispose();
    super.dispose();
  }

  Future<void> _saveLastPlayback({
    String? uriOverride,
    Duration? positionOverride,
  }) async {
    final uri = uriOverride ?? _currentUri;
    if (uri.isEmpty) return;

    final position = positionOverride ?? _audioPlayer.position;
    _lastKnownPosition = position;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastPlayedUriKey, uri);
      await prefs.setInt(
        _lastPlayedPositionKey,
        position.inMilliseconds,
      );
    } catch (e) {
      debugPrint('LAST PLAYED SAVE ERROR: $e');
    }
  }

  Future<void> _restoreLastPlayback() async {
    if (_restoringLastPlayback) return;
    _restoringLastPlayback = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUri = prefs.getString(_lastPlayedUriKey) ?? '';
      final savedPositionMs =
          prefs.getInt(_lastPlayedPositionKey) ?? 0;

      if (savedUri.isEmpty || !mounted) return;

      final songs = await _songsFuture;
      final index = songs.indexWhere(
            (song) => song['uri']?.toString() == savedUri,
      );

      if (index < 0 || !mounted) return;

      final song = songs[index];
      final uri = song['uri']?.toString() ?? '';
      if (uri.isEmpty) return;

      setState(() {
        _currentTitle =
            song['title']?.toString() ?? 'Unknown title';
        _currentArtist =
            song['artist']?.toString() ?? 'Unknown Artist';
        _currentUri = uri;
        _currentArtworkPath =
            song['artworkPath']?.toString() ?? '';
        _currentSongIndex = index;
        _queuePosition = -1;
      });

      _miniPlayerData.value = MiniPlayerData(
        title: _currentTitle,
        artist: _currentArtist,
        artworkUri: _currentArtworkPath,
      );

      await _audioPlayer.setAudioSource(
        AudioSource.uri(Uri.parse(uri)),
      );
      await _syncAudioSession(_audioPlayer);

      var restorePosition = Duration(
        milliseconds: savedPositionMs.clamp(0, 1 << 31).toInt(),
      );

      final duration = _audioPlayer.duration;
      if (duration != null && restorePosition > duration) {
        restorePosition = duration;
      }

      await _audioPlayer.seek(restorePosition);
      _lastKnownPosition = restorePosition;
    } catch (e) {
      debugPrint('LAST PLAYED RESTORE ERROR: $e');
    } finally {
      _restoringLastPlayback = false;
    }
  }

// =====================================================
// SCAN MUSIC
// =====================================================

  Future<List<Map<String, dynamic>>> _loadSongs() async {
    // Show the last known library immediately. A fresh MediaStore scan then
    // runs in the background so Home does not have to wait on the scanner.
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString(_songsCacheKey);

      if (cachedJson != null && cachedJson.isNotEmpty) {
        final decoded = jsonDecode(cachedJson);
        if (decoded is List) {
          final cachedSongs = decoded
              .whereType<Map>()
              .map((song) => Map<String, dynamic>.from(song))
              .toList();

          if (cachedSongs.isNotEmpty) {
            unawaited(_refreshSongsInBackground());
            return cachedSongs;
          }
        }
      }
    } catch (e) {
      debugPrint('SONG CACHE READ ERROR: $e');
    }

    return _scanFreshSongs();
  }

  Future<List<Map<String, dynamic>>> _scanFreshSongs() async {
    try {
      final List<dynamic> result =
      await _musicChannel.invokeMethod('scanMusic');

      final songs = result
          .map((song) => Map<String, dynamic>.from(song as Map))
          .toList();

      await _saveSongsCache(songs);

      // Artwork and genre extraction is deliberately separated from the fast
      // MediaStore scan. It runs off the UI thread and updates the library
      // after Home is already usable.
      unawaited(_enrichSongsInBackground(songs));

      return songs;
    } catch (e) {
      debugPrint('MUSIC SCAN ERROR: $e');
      return [];
    }
  }

  Future<void> _refreshSongsInBackground() async {
    final songs = await _scanFreshSongs();
    if (!mounted) return;

    setState(() {
      _songsFuture = Future<List<Map<String, dynamic>>>.value(songs);
    });
  }

  Future<void> _enrichSongsInBackground(
      List<Map<String, dynamic>> baseSongs,
      ) async {
    try {
      final List<dynamic> result = await _musicChannel.invokeMethod(
        'enrichMusicMetadata',
      );

      final metadataById = <String, Map<String, dynamic>>{};
      for (final item in result) {
        final map = Map<String, dynamic>.from(item as Map);
        final id = map['id']?.toString() ?? '';
        if (id.isNotEmpty) metadataById[id] = map;
      }

      if (metadataById.isEmpty) return;

      final enriched = baseSongs.map((song) {
        final copy = Map<String, dynamic>.from(song);
        final meta = metadataById[copy['id']?.toString() ?? ''];
        if (meta != null) {
          final genre = meta['genre']?.toString() ?? '';
          final artworkPath = meta['artworkPath']?.toString() ?? '';
          if (genre.isNotEmpty) copy['genre'] = genre;
          if (artworkPath.isNotEmpty) copy['artworkPath'] = artworkPath;
        }
        return copy;
      }).toList();

      await _saveSongsCache(enriched);

      if (!mounted) return;

      final currentUri = _currentUri;
      if (currentUri.isNotEmpty) {
        final current = enriched.firstWhere(
              (song) => song['uri']?.toString() == currentUri,
          orElse: () => <String, dynamic>{},
        );
        final artwork = current['artworkPath']?.toString() ?? '';
        if (artwork.isNotEmpty && artwork != _currentArtworkPath) {
          _currentArtworkPath = artwork;
          _miniPlayerData.value = MiniPlayerData(
            title: _currentTitle,
            artist: _currentArtist,
            artworkUri: artwork,
          );
        }
      }

      setState(() {
        _songsFuture = Future<List<Map<String, dynamic>>>.value(enriched);
      });
    } catch (e) {
      debugPrint('MUSIC METADATA ENRICH ERROR: $e');
    }
  }

  Future<void> _saveSongsCache(
      List<Map<String, dynamic>> songs,
      ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_songsCacheKey, jsonEncode(songs));
    } catch (e) {
      debugPrint('SONG CACHE WRITE ERROR: $e');
    }
  }

// =====================================================
// PLAY SONG
// =====================================================

  Future<void> _playSong(
      Map<String, dynamic> song,
      int index,
      {int? queuePosition,}
      ) async {
    final uri = song['uri']?.toString() ?? '';

    if (uri.isEmpty) {
      return;
    }

    try {
      // Wait for the startup restore so a quick tap cannot race it.
      final restoreFuture = _restoreFuture;
      if (restoreFuture != null) {
        await restoreFuture;
      }

      final songs = await _songsFuture;

      // Keep the old song/position before changing the current-song fields.
      final previousUri = _currentUri;
      final previousPosition = _audioPlayer.position;
      if (previousUri.isNotEmpty && previousUri != uri) {
        await _saveLastPlayback(
          uriOverride: previousUri,
          positionOverride: previousPosition,
        );
      }

// On the first play, create a queue using the current library order.
      if (_queueIndices.isEmpty) {
        _queueIndices
          ..clear()
          ..addAll(List<int>.generate(songs.length, (i) => i));
      }

      int resolvedQueuePosition = queuePosition ??
          _queueIndices.indexOf(index);

      if (resolvedQueuePosition < 0) {
        _queueIndices.add(index);
        resolvedQueuePosition = _queueIndices.length - 1;
      }

      setState(() {
        _currentTitle =
            song['title']?.toString() ?? 'Unknown title';

        _currentArtist =
            song['artist']?.toString() ?? 'Unknown Artist';

        _currentUri = uri;
        _currentArtworkPath =
            song['artworkPath']?.toString() ?? '';
        _currentSongIndex = index;
        _queuePosition = resolvedQueuePosition;
      });

      _miniPlayerData.value = MiniPlayerData(
        title: _currentTitle,
        artist: _currentArtist,
        artworkUri: _currentArtworkPath,
      );

      await _audioPlayer.setAudioSource(
        AudioSource.uri(Uri.parse(uri)),
      );

      await _syncAudioSession(_audioPlayer);

      _lastKnownPosition = Duration.zero;
      await _saveLastPlayback(
        uriOverride: uri,
        positionOverride: Duration.zero,
      );

      await _audioPlayer.play();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not play song: $e'),
        ),
      );
    }
  }

// =====================================================
// NEXT
// =====================================================

  Future<void> _nextSong() async {
    final songs = await _songsFuture;

    if (_queueIndices.isEmpty) {
      if (_currentSongIndex < 0 ||
          _currentSongIndex >= songs.length - 1) {
        return;
      }
      await _playSong(
        songs[_currentSongIndex + 1],
        _currentSongIndex + 1,
      );
      return;
    }

    final nextPosition = _queuePosition + 1;

    if (nextPosition < 0 ||
        nextPosition >= _queueIndices.length) {
      return;
    }

    final nextIndex = _queueIndices[nextPosition];

    if (nextIndex < 0 || nextIndex >= songs.length) {
      return;
    }

    await _playSong(
      songs[nextIndex],
      nextIndex,
      queuePosition: nextPosition,
    );
  }

// =====================================================
// PREVIOUS
// =====================================================

  Future<void> _previousSong() async {
    final songs = await _songsFuture;

    if (_queueIndices.isEmpty) {
      if (_currentSongIndex <= 0 ||
          _currentSongIndex >= songs.length) {
        return;
      }
      await _playSong(
        songs[_currentSongIndex - 1],
        _currentSongIndex - 1,
      );
      return;
    }

    final previousPosition = _queuePosition - 1;

    if (previousPosition < 0 ||
        previousPosition >= _queueIndices.length) {
      return;
    }

    final previousIndex = _queueIndices[previousPosition];

    if (previousIndex < 0 || previousIndex >= songs.length) {
      return;
    }

    await _playSong(
      songs[previousIndex],
      previousIndex,
      queuePosition: previousPosition,
    );
  }

// =====================================================
// OPEN NOW PLAYING
// =====================================================

  Future<void> _openNowPlaying() async {
    if (_currentSongIndex < 0) {
      return;
    }

    if (!mounted) {
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NowPlayingPage(
          audioPlayer: _audioPlayer,
          songsFuture: _songsFuture,
          currentIndex: _currentSongIndex,
          queueIndices: List<int>.from(_queueIndices),
          onOpenQueue: _openQueue,
          onSongChanged: (index, song) {
            setState(() {
              _currentSongIndex = index;

              _currentTitle =
                  song['title']?.toString() ??
                      'Unknown title';

              _currentArtist =
                  song['artist']?.toString() ??
                      'Unknown Artist';

              _currentUri =
                  song['uri']?.toString() ?? '';
              _currentArtworkPath =
                  song['artworkPath']?.toString() ?? '';
              _queuePosition = _queueIndices.indexOf(index);
            });

            _miniPlayerData.value = MiniPlayerData(
              title: _currentTitle,
              artist: _currentArtist,
              artworkUri: _currentArtworkPath,
            );
          },
        ),
      ),
    );

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadBluetoothStatus() async {
    try {
      final devices = await _getBluetoothDevices();
      final connected = devices.firstWhere(
            (device) => device['connected'] == true,
        orElse: () => <String, dynamic>{},
      );
      if (!mounted) return;
      setState(() {
        _connectedBluetoothName = connected['name']?.toString() ?? '';
      });
    } catch (e) {
      debugPrint('BLUETOOTH STATUS ERROR: $e');
    }
  }

  Future<void> _openBluetoothDevices() async {
    try {
      final devices = await _getBluetoothDevices();
      final connected = devices
          .where((device) => device['connected'] == true)
          .toList();

      if (!mounted) return;

      if (connected.isEmpty) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFF151515),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Row(
              children: [
                Icon(Icons.bluetooth_disabled, color: Colors.white70, size: 26),
                SizedBox(width: 10),
                Text(
                  'Bluetooth',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            content: const Text(
              'No Bluetooth device connected.',
              style: TextStyle(color: Colors.white70, fontSize: 15),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text(
                  'OK',
                  style: TextStyle(color: Color(0xFF2196F3)),
                ),
              ),
            ],
          ),
        );
      } else {
        await showModalBottomSheet<void>(
          context: context,
          backgroundColor: Colors.transparent,
          builder: (_) => _ConnectedBluetoothSheet(devices: connected),
        );
      }

      _loadBluetoothStatus();
    } on PlatformException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF151515),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'Bluetooth',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Text(
            e.message ?? 'Bluetooth is not available right now.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text(
                'OK',
                style: TextStyle(color: Color(0xFF2196F3)),
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not read Bluetooth status: $e')),
      );
    }
  }

// =====================================================
// QUEUE
// =====================================================

  Future<List<int>> _openQueue() async {
    final songs = await _songsFuture;

    if (!mounted) return List<int>.from(_queueIndices);

    if (_queueIndices.isEmpty) {
      setState(() {
        _queueIndices.addAll(
          List<int>.generate(songs.length, (i) => i),
        );
        _queuePosition = _queueIndices.indexOf(_currentSongIndex);
      });
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(24),
        ),
      ),
      builder: (_) => QueueSheet(
        songs: songs,
        queueIndices: List<int>.from(_queueIndices),
        currentSongIndex: _currentSongIndex,
        onPlay: (queuePosition) async {
          if (queuePosition < 0 ||
              queuePosition >= _queueIndices.length) {
            return;
          }

          final index = _queueIndices[queuePosition];

          if (index < 0 || index >= songs.length) return;

          await _playSong(
            songs[index],
            index,
            queuePosition: queuePosition,
          );
        },
        onRemove: (songIndex) {
          final removedPosition =
          _queueIndices.indexOf(songIndex);

          if (removedPosition < 0 ||
              songIndex == _currentSongIndex) {
            return;
          }

          setState(() {
            _queueIndices.removeAt(removedPosition);

            if (removedPosition < _queuePosition) {
              _queuePosition--;
            }
          });
        },
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) {
              newIndex -= 1;
            }

            final movedSong =
            _queueIndices.removeAt(oldIndex);
            _queueIndices.insert(newIndex, movedSong);
            _queuePosition =
                _queueIndices.indexOf(_currentSongIndex);
          });
        },
      ),
    );

    if (mounted) {
      setState(() {});
    }

    return List<int>.from(_queueIndices);
  }

// =====================================================
// FAVOURITES
// =====================================================

  Future<void> _openFavourites() async {
    final songs = await _songsFuture;
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FavouritesPage(
          songs: songs,
          onPlay: (index) async {
            await _playSong(songs[index], index);
          },
          miniPlayer: _miniPlayerConfig,
        ),
      ),
    );

    if (mounted) setState(() {});
  }

// =====================================================
// ARTISTS
// =====================================================

  Future<void> _openArtists() async {
    final songs = await _songsFuture;
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistsPage(
          songs: songs,
          onPlay: (index) async {
            await _playSong(songs[index], index);
          },
          miniPlayer: _miniPlayerConfig,
        ),
      ),
    );

    if (mounted) setState(() {});
  }

// =====================================================
// ALBUMS / MOVIES
// =====================================================

  Future<void> _openAlbums() async {
    final songs = await _songsFuture;
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlbumsPage(
          songs: songs,
          onPlay: (index) async {
            await _playSong(songs[index], index);
          },
          miniPlayer: _miniPlayerConfig,
        ),
      ),
    );

    if (mounted) setState(() {});
  }


  Future<void> _openGenres() async {
    final songs = await _songsFuture;
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GenresPage(
          songs: songs,
          onPlay: (index) async {
            await _playSong(songs[index], index);
          },
          miniPlayer: _miniPlayerConfig,
        ),
      ),
    );

    if (mounted) setState(() {});
  }


// =====================================================
// PLAYLISTS
// =====================================================

  Future<void> _openDuplicateCleaner() async {
    final songs = await _songsFuture;
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DuplicateCleanerPage(songs: songs),
      ),
    );

    // Refresh the library after returning because a duplicate may have been deleted.
    if (!mounted) return;
    setState(() {
      _songsFuture = _loadSongs();
    });
  }

  Future<void> _openPlaylists() async {
    final songs = await _songsFuture;
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistsPage(
          songs: songs,
          onPlayPlaylistSong: _playPlaylistSong,
          miniPlayer: _miniPlayerConfig,
        ),
      ),
    );

    if (mounted) setState(() {});
  }

  Future<void> _playPlaylistSong(
      List<int> playlistIndices,
      int selectedIndex,
      ) async {
    final songs = await _songsFuture;
    if (selectedIndex < 0 || selectedIndex >= songs.length) return;
    if (playlistIndices.isEmpty) return;

    final validQueue = playlistIndices
        .where((index) => index >= 0 && index < songs.length)
        .toList();
    if (validQueue.isEmpty || !validQueue.contains(selectedIndex)) return;

    final position = validQueue.indexOf(selectedIndex);

    setState(() {
      _queueIndices
        ..clear()
        ..addAll(validQueue);
      _queuePosition = position;
    });

    await _playSong(
      songs[selectedIndex],
      selectedIndex,
      queuePosition: position,
    );
  }

// =====================================================
// SHARED MINI PLAYER CONFIG
// =====================================================

  MiniPlayerConfig get _miniPlayerConfig => MiniPlayerConfig(
    audioPlayer: _audioPlayer,
    data: _miniPlayerData,
    onOpen: _openNowPlaying,
    onPrevious: _previousSong,
    onNext: _nextSong,
  );

// =====================================================
// SEARCH
// =====================================================

  Future<void> _openSearch() async {
    final songs = await _songsFuture;
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SearchPage(
          songs: songs,
          onPlay: (index) async {
            await _playSong(songs[index], index);
          },
          miniPlayer: _miniPlayerConfig,
        ),
      ),
    );

    if (mounted) setState(() {});
  }

// =====================================================
// BUILD
// =====================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _songsFuture,
          builder: (context, snapshot) {
            final songs = snapshot.data ?? const <Map<String, dynamic>>[];
            final loading = snapshot.connectionState == ConnectionState.waiting;

            return CustomScrollView(
              cacheExtent: 360,
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Your Music',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: _connectedBluetoothName.isEmpty
                                    ? 'Bluetooth devices'
                                    : _connectedBluetoothName,
                                icon: Icon(
                                  Icons.bluetooth,
                                  color: _connectedBluetoothName.isEmpty
                                      ? Colors.white
                                      : const Color(0xFF2196F3),
                                  size: 24,
                                ),
                                onPressed: _openBluetoothDevices,
                              ),
                              IconButton(
                                icon: const Icon(Icons.search, color: Colors.white, size: 24),
                                onPressed: _openSearch,
                              ),
                              IconButton(
                                icon: const Icon(Icons.settings_outlined, color: Colors.white, size: 24),
                                onPressed: () {},
                              ),
                            ],
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: _homeCapsule(
                                Icons.person_outline,
                                'Artists',
                                'Browse artists',
                                onTap: _openArtists,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _homeCapsule(
                                Icons.album_outlined,
                                'Albums',
                                'Browse movies',
                                onTap: _openAlbums,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _homeCapsule(
                                Icons.queue_music,
                                'Playlists',
                                'Your playlists',
                                onTap: _openPlaylists,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _homeCapsule(
                                Icons.favorite,
                                'Favourites',
                                'Liked songs',
                                onTap: _openFavourites,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: _homeCapsule(
                                Icons.music_note,
                                'Genres',
                                'Browse by genre',
                                onTap: _openGenres,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _homeCapsule(
                                Icons.library_music_outlined,
                                'Duplicate Cleaner',
                                'Find duplicates',
                                onTap: _openDuplicateCleaner,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Last Played',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            TextButton(
                              onPressed: () {},
                              child: const Text(
                                'See all',
                                style: TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (_currentSongIndex < 0)
                          const ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.music_note, color: Colors.white54),
                            title: Text(
                              'No songs played yet',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                              'Your recently played songs will appear here',
                              style: TextStyle(color: Colors.white54),
                            ),
                          )
                        else
                          _lastPlayedTile(),
                        const SizedBox(height: 24),
                        const Text(
                          'All Songs',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
                if (loading)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 30),
                      child: Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      ),
                    ),
                  )
                else if (songs.isEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20, 10, 20, 30),
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.music_off, color: Colors.white54),
                        title: Text('No music found', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                            (context, index) => _songTile(songs[index], index),
                        childCount: songs.length,
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: true,
                        addSemanticIndexes: false,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: SharedMiniPlayer(config: _miniPlayerConfig),
    );
  }

  Widget _homeCapsule(
      IconData icon,
      String title,
      String subtitle, {
        VoidCallback? onTap,
      }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 88,
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 9,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF171717),
          borderRadius: BorderRadius.circular(44),
          border: Border.all(
            color: Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Container(
              height: 54,
              width: 54,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(27),
              ),
              child: Icon(
                icon,
                color: Colors.black,
                size: 26,
              ),
            ),

            const SizedBox(width: 9),

            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),

            const Icon(
              Icons.chevron_right,
              color: Colors.white54,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

// =====================================================
// LIBRARY TILE
// =====================================================

  Widget _libraryTile(
      IconData icon,
      String title,
      ) {
    return Expanded(
      child: Column(
        children: [
          Container(
            height: 60,
            width: 60,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius:
              BorderRadius.circular(17),
            ),
            child: Icon(
              icon,
              color: Colors.black,
              size: 26,
            ),
          ),

          const SizedBox(height: 7),

          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

// =====================================================
// LAST PLAYED TILE
// =====================================================

  Widget _lastPlayedTile() {
    return ListTile(
      contentPadding: EdgeInsets.zero,

      leading: _artwork(
        _currentArtworkPath,
        55,
      ),

      title: Text(
        _currentTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),

      subtitle: Text(
        _currentArtist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 13,
        ),
      ),

      onTap: _openNowPlaying,
    );
  }

// =====================================================
// SCANNED SONGS
// =====================================================

  Widget _scannedSongs() {
    return FutureBuilder<
        List<Map<String, dynamic>>>(
      future: _songsFuture,

      builder: (context, snapshot) {

        if (snapshot.connectionState ==
            ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(
              vertical: 20,
            ),
            child: Center(
              child: CircularProgressIndicator(
                color: Colors.white,
              ),
            ),
          );
        }

        final songs =
            snapshot.data ?? [];

        if (songs.isEmpty) {
          return const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.music_off,
              color: Colors.white54,
            ),
            title: Text(
              'No music found',
              style: TextStyle(
                color: Colors.white,
              ),
            ),
          );
        }

        return Column(
          children: songs
              .asMap()
              .entries
              .map(
                (entry) => _songTile(
              entry.value,
              entry.key,
            ),
          )
              .toList(),
        );
      },
    );
  }

// =====================================================
// SONG TILE
// =====================================================

  Widget _songTile(
      Map<String, dynamic> song,
      int index,
      ) {
    final title =
        song['title']?.toString() ??
            'Unknown title';

    final album =
        song['album']?.toString() ??
            'Unknown Album';

    final uri =
        song['uri']?.toString() ?? '';

    final duration =
    song['duration'] is num
        ? Duration(
      milliseconds:
      (song['duration'] as num)
          .toInt(),
    )
        : Duration.zero;

    return SizedBox(
      height: 88,
      child: InkWell(
        onTap: () {
          _playSong(song, index);
        },

        child: Row(
          children: [

// ARTWORK
            _artwork(
              song['artworkPath']?.toString() ?? '',
              50,
            ),

            const SizedBox(width: 14),

// SONG + ALBUM
            Expanded(
              child: Column(
                mainAxisAlignment:
                MainAxisAlignment.center,
                crossAxisAlignment:
                CrossAxisAlignment.start,
                children: [

                  Text(
                    title,
                    maxLines: 2,
                    overflow:
                    TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight:
                      FontWeight.bold,
                      height: 1.05,
                    ),
                  ),

                  const SizedBox(height: 3),

                  Text(
                    album,
                    maxLines: 1,
                    overflow:
                    TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                      height: 1.05,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 6),

// DURATION + MENU
            Column(
              mainAxisAlignment:
              MainAxisAlignment.center,
              children: [

                Text(
                  _formatDuration(duration),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                ),

                const SizedBox(height: 4),

                const Icon(
                  Icons.more_vert,
                  color: Colors.white,
                  size: 18,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

// =====================================================
// FEATURE TILE
// =====================================================

  Widget _featureTile(
      IconData icon,
      String title,
      String subtitle,
      ) {
    return Container(
      height: 72,
      margin:
      const EdgeInsets.only(bottom: 8),
      padding:
      const EdgeInsets.symmetric(
        horizontal: 12,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius:
        BorderRadius.circular(14),
      ),
      child: Row(
        children: [

          Container(
            height: 44,
            width: 44,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius:
              BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: Colors.black,
              size: 23,
            ),
          ),

          const SizedBox(width: 12),

          Expanded(
            child: Column(
              mainAxisAlignment:
              MainAxisAlignment.center,
              crossAxisAlignment:
              CrossAxisAlignment.start,
              children: [

                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight:
                    FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 2),

                Text(
                  subtitle,
                  maxLines: 1,
                  overflow:
                  TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          const Icon(
            Icons.chevron_right,
            color: Colors.white54,
            size: 20,
          ),
        ],
      ),
    );
  }

// =====================================================
// ARTWORK
// =====================================================

  Widget _artwork(String path, double size) {
    final file = path.isNotEmpty ? File(path) : null;

    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: file != null
          ? Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).round(),
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) {
          return const Icon(
            Icons.music_note,
            color: Colors.black,
            size: 34,
          );
        },
      )
          : const Icon(
        Icons.music_note,
        color: Colors.black,
        size: 34,
      ),
    );
  }

// =====================================================
// FORMAT DURATION
// =====================================================

  String _formatDuration(
      Duration duration,
      ) {
    if (duration == Duration.zero) {
      return '--:--';
    }

    final minutes =
    duration.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');

    final seconds =
    duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');

    if (duration.inHours > 0) {
      return '${duration.inHours}:$minutes:$seconds';
    }

    return '$minutes:$seconds';
  }
}

// =====================================================
// SHARED MINI PLAYER STATE
// =====================================================

class _ConnectedBluetoothSheet extends StatelessWidget {
  final List<Map<String, dynamic>> devices;

  const _ConnectedBluetoothSheet({required this.devices});

  IconData _deviceIcon(Map<String, dynamic> device) {
    final type = (device['type'] ?? '').toString();
    if (type == 'car') return Icons.directions_car_outlined;
    if (type == 'speaker') return Icons.speaker_outlined;
    return Icons.headphones_outlined;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        decoration: BoxDecoration(
          color: const Color(0xFF151515),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth, color: Color(0xFF2196F3), size: 25),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Bluetooth',
                    style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white54),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ...devices.map((device) {
              final name = device['name']?.toString().trim();
              final displayName = (name == null || name.isEmpty) ? 'Bluetooth device' : name;
              final battery = device['battery'] is num ? (device['battery'] as num).toInt() : -1;

              return Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1B1B),
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(color: const Color(0xFF2196F3).withOpacity(0.45)),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: const Color(0xFF242424),
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Icon(_deviceIcon(device), color: Colors.white, size: 27),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 5),
                          const Row(
                            children: [
                              Icon(Icons.circle, color: Color(0xFF20D66B), size: 8),
                              SizedBox(width: 6),
                              Text('Connected', style: TextStyle(color: Color(0xFF20D66B), fontSize: 12, fontWeight: FontWeight.w600)),
                            ],
                          ),
                          if (battery >= 0) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Icon(Icons.battery_full, color: Color(0xFF20D66B), size: 17),
                                const SizedBox(width: 5),
                                Text('$battery%', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const Icon(Icons.bluetooth, color: Color(0xFF2196F3), size: 24),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class MiniPlayerData {
  final String title;
  final String artist;
  final String artworkUri;

  const MiniPlayerData({
    required this.title,
    required this.artist,
    required this.artworkUri,
  });
}

class MiniPlayerConfig {
  final AudioPlayer audioPlayer;
  final ValueListenable<MiniPlayerData?> data;
  final Future<void> Function() onOpen;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;

  const MiniPlayerConfig({
    required this.audioPlayer,
    required this.data,
    required this.onOpen,
    required this.onPrevious,
    required this.onNext,
  });
}

class SharedMiniPlayer extends StatelessWidget {
  final MiniPlayerConfig config;

  const SharedMiniPlayer({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MiniPlayerData?>(
      valueListenable: config.data,
      builder: (context, data, _) {
        if (data == null) return const SizedBox.shrink();

        return MiniPlayer(
          audioPlayer: config.audioPlayer,
          title: data.title,
          artist: data.artist,
          artworkUri: data.artworkUri,
          onOpen: config.onOpen,
          onPrevious: config.onPrevious,
          onNext: config.onNext,
        );
      },
    );
  }
}

class MiniPlayer extends StatelessWidget {
  final AudioPlayer audioPlayer;

  final String title;
  final String artist;
  final String artworkUri;

  final VoidCallback? onOpen;

  final Future<void> Function()? onPrevious;
  final Future<void> Function()? onNext;

  const MiniPlayer({
    super.key,
    required this.audioPlayer,
    required this.title,
    required this.artist,
    required this.artworkUri,
    this.onOpen,
    this.onPrevious,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,

      decoration: const BoxDecoration(
        color: Color(0xFF151515),
        border: Border(
          top: BorderSide(
            color: Colors.white12,
          ),
        ),
      ),

      padding:
      const EdgeInsets.symmetric(
        horizontal: 10,
      ),

      child: Row(
        children: [

// =================================================
// SONG INFO
// =================================================

          Expanded(
            child: GestureDetector(
              onTap: onOpen,

              child: Row(
                children: [

                  _miniArtwork(),

                  const SizedBox(width: 9),

                  Expanded(
                    child: Column(
                      mainAxisAlignment:
                      MainAxisAlignment.center,
                      crossAxisAlignment:
                      CrossAxisAlignment.start,
                      children: [

                        Text(
                          title,
                          maxLines: 1,
                          overflow:
                          TextOverflow.ellipsis,
                          style:
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight:
                            FontWeight.w600,
                          ),
                        ),

                        const SizedBox(
                          height: 2,
                        ),

                        Text(
                          artist,
                          maxLines: 1,
                          overflow:
                          TextOverflow.ellipsis,
                          style:
                          const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

// =================================================
// PREVIOUS
// =================================================

          IconButton(
            onPressed: onPrevious,

            icon: const Icon(
              Icons.skip_previous,
              color: Colors.white,
              size: 25,
            ),
          ),

// =================================================
// PLAY / PAUSE
// =================================================

          StreamBuilder<bool>(
            stream:
            audioPlayer.playingStream,

            builder:
                (context, snapshot) {

              final isPlaying =
                  snapshot.data == true;

              return Container(
                height: 40,
                width: 40,

                decoration:
                const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),

                child: IconButton(
                  padding: EdgeInsets.zero,

                  onPressed: () async {
                    if (isPlaying) {
                      await audioPlayer.pause();
                    } else {
                      await audioPlayer.play();
                    }
                  },

                  icon: Icon(
                    isPlaying
                        ? Icons.pause
                        : Icons.play_arrow,

                    color: Colors.black,
                    size: 23,
                  ),
                ),
              );
            },
          ),

// =================================================
// NEXT
// =================================================

          IconButton(
            onPressed: onNext,

            icon: const Icon(
              Icons.skip_next,
              color: Colors.white,
              size: 25,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniArtwork() {
    final file =
    artworkUri.isNotEmpty ? File(artworkUri) : null;

    return Container(
      height: 50,
      width: 50,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: file != null
          ? Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: 100,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) {
          return const Icon(
            Icons.music_note,
            color: Colors.black,
            size: 24,
          );
        },
      )
          : const Icon(
        Icons.music_note,
        color: Colors.black,
        size: 24,
      ),
    );
  }
}

// =====================================================
// QUEUE SHEET
// =====================================================

class QueueSheet extends StatefulWidget {
  final List<Map<String, dynamic>> songs;
  final List<int> queueIndices;
  final int currentSongIndex;
  final Future<void> Function(int queuePosition) onPlay;
  final void Function(int songIndex) onRemove;
  final void Function(int oldIndex, int newIndex) onReorder;

  const QueueSheet({
    super.key,
    required this.songs,
    required this.queueIndices,
    required this.currentSongIndex,
    required this.onPlay,
    required this.onRemove,
    required this.onReorder,
  });

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet> {
  late List<int> _queue;

  @override
  void initState() {
    super.initState();
    _queue = List<int>.from(widget.queueIndices);
  }

  String _duration(dynamic value) {
    if (value is! num) return '--:--';

    final duration =
    Duration(milliseconds: value.toInt());

    final minutes = duration.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final seconds = duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');

    return '${duration.inHours > 0 ? '${duration.inHours}:' : ''}$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            const SizedBox(height: 10),

            Container(
              height: 4,
              width: 40,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Queue',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(
                    '${_queue.length} songs',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: _queue.isEmpty
                  ? const Center(
                child: Text(
                  'Queue is empty',
                  style: TextStyle(
                    color: Colors.white54,
                  ),
                ),
              )
                  : ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                itemCount: _queue.length,
                onReorder: (oldIndex, newIndex) {
                  setState(() {
                    if (newIndex > oldIndex) newIndex -= 1;
                    final moved = _queue.removeAt(oldIndex);
                    _queue.insert(newIndex, moved);
                  });

                  widget.onReorder(oldIndex, newIndex);
                },
                itemBuilder: (context, position) {
                  final songIndex = _queue[position];

                  if (songIndex < 0 ||
                      songIndex >= widget.songs.length) {
                    return const SizedBox.shrink(
                      key: ValueKey('invalid'),
                    );
                  }

                  final song = widget.songs[songIndex];
                  final title =
                      song['title']?.toString() ?? 'Unknown title';
                  final artist =
                      song['artist']?.toString() ?? 'Unknown Artist';
                  final artwork =
                      song['artworkPath']?.toString() ?? '';
                  final isCurrent =
                      songIndex == widget.currentSongIndex;

                  return Container(
                    key: ValueKey('queue_$songIndex'),
                    margin: const EdgeInsets.only(bottom: 4),
                    child: ListTile(
                      onTap: () async {
                        await widget.onPlay(position);
                        if (context.mounted) {
                          Navigator.pop(context);
                        }
                      },
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                      ),
                      leading: _QueueArtwork(
                        path: artwork,
                      ),
                      title: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent
                              ? Colors.white
                              : Colors.white,
                          fontWeight: isCurrent
                              ? FontWeight.bold
                              : FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _duration(song['duration']),
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          if (!isCurrent)
                            PopupMenuButton<String>(
                              color: const Color(0xFF202020),
                              icon: const Icon(
                                Icons.more_vert,
                                color: Colors.white54,
                                size: 20,
                              ),
                              onSelected: (value) {
                                if (value == 'remove') {
                                  final removedPosition =
                                  _queue.indexOf(songIndex);
                                  if (removedPosition < 0) return;

                                  setState(() {
                                    _queue.removeAt(removedPosition);
                                  });
                                  widget.onRemove(songIndex);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem<String>(
                                  value: 'remove',
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.remove_circle_outline,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                      SizedBox(width: 12),
                                      Text(
                                        'Remove from Queue',
                                        style: TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ReorderableDragStartListener(
                            index: position,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(
                                Icons.drag_handle,
                                color: Colors.white54,
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueArtwork extends StatelessWidget {
  final String path;

  const _QueueArtwork({required this.path});

  @override
  Widget build(BuildContext context) {
    final file = path.isNotEmpty ? File(path) : null;

    return Container(
      height: 52,
      width: 52,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: file != null
          ? Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: 104,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) => const Icon(
          Icons.music_note,
          color: Colors.black,
        ),
      )
          : const Icon(
        Icons.music_note,
        color: Colors.black,
      ),
    );
  }
}

// =====================================================
// FAVOURITES PAGE
// =====================================================

class FavouritesPage extends StatefulWidget {
  final List<Map<String, dynamic>> songs;
  final Future<void> Function(int index) onPlay;
  final MiniPlayerConfig miniPlayer;

  const FavouritesPage({
    super.key,
    required this.songs,
    required this.onPlay,
    required this.miniPlayer,
  });

  @override
  State<FavouritesPage> createState() => _FavouritesPageState();
}

class _FavouritesPageState extends State<FavouritesPage> {
  late Future<Set<String>> _favouritesFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _favouritesFuture = FavoriteStore.getAll();
  }

  Future<void> _removeFavourite(String uri) async {
    await FavoriteStore.setFavourite(uri, false);
    if (!mounted) return;
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Favourites',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: FutureBuilder<Set<String>>(
        future: _favouritesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }

          final favouriteUris = snapshot.data ?? <String>{};
          final favouriteSongs = <MapEntry<int, Map<String, dynamic>>>[];

          for (var i = 0; i < widget.songs.length; i++) {
            final song = widget.songs[i];
            final uri = song['uri']?.toString() ?? '';
            if (favouriteUris.contains(uri)) {
              favouriteSongs.add(MapEntry(i, song));
            }
          }

          if (favouriteSongs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.favorite_border, color: Colors.white54, size: 64),
                  SizedBox(height: 14),
                  Text(
                    'No favourite songs yet',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Tap the heart on Now Playing to add songs',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
            itemCount: favouriteSongs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, position) {
              final entry = favouriteSongs[position];
              final index = entry.key;
              final song = entry.value;
              final title = song['title']?.toString() ?? 'Unknown title';
              final artist = song['artist']?.toString() ?? 'Unknown Artist';
              final artworkPath = song['artworkPath']?.toString() ?? '';

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: artworkPath.isNotEmpty
                        ? Image.file(
                      File(artworkPath),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.music_note,
                        color: Colors.white,
                      ),
                    )
                        : const Icon(
                      Icons.music_note,
                      color: Colors.white,
                    ),
                  ),
                ),
                title: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54),
                ),
                trailing: IconButton(
                  tooltip: 'Remove from Favourites',
                  onPressed: () => _removeFavourite(
                    song['uri']?.toString() ?? '',
                  ),
                  icon: const Icon(
                    Icons.favorite,
                    color: Colors.white,
                  ),
                ),
                onTap: () async {
                  await widget.onPlay(index);
                },
              );
            },
          );
        },
      ),
      bottomNavigationBar: SharedMiniPlayer(config: widget.miniPlayer),
    );
  }
}

// =====================================================
// NOW PLAYING
// =====================================================

class NowPlayingPage extends StatefulWidget {
  final AudioPlayer audioPlayer;

  final Future<List<Map<String, dynamic>>>
  songsFuture;

  final int currentIndex;

  final List<int> queueIndices;
  final Future<List<int>> Function()? onOpenQueue;

  final void Function(
      int index,
      Map<String, dynamic> song,
      ) onSongChanged;

  const NowPlayingPage({
    super.key,
    required this.audioPlayer,
    required this.songsFuture,
    required this.currentIndex,
    required this.queueIndices,
    this.onOpenQueue,
    required this.onSongChanged,
  });

  @override
  State<NowPlayingPage> createState() =>
      _NowPlayingPageState();
}

class _NowPlayingPageState
    extends State<NowPlayingPage> {

  late int _currentIndex;
  late int _queuePosition;
  late List<int> _queueIndices;

  bool _isFavourite = false;
  bool _shuffleEnabled = false;
  LoopMode _repeatMode = LoopMode.off;
  StreamSubscription<ProcessingState>? _processingSubscription;

  @override
  void initState() {
    super.initState();

    _currentIndex =
        widget.currentIndex;
    _queueIndices = List<int>.from(widget.queueIndices);
    _queuePosition =
        _queueIndices.indexOf(_currentIndex);

// We use our own shuffle/repeat logic because each song is loaded
// as a single AudioSource rather than one ConcatenatingAudioSource.
    _processingSubscription =
        widget.audioPlayer.processingStateStream.listen((state) {
          if (state == ProcessingState.completed && mounted) {
            _nextSong();
          }
        });

    _loadFavourite();
  }

  @override
  void dispose() {
    _processingSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadFavourite() async {
    final song = await _currentSong();
    if (song == null) return;
    final uri = song['uri']?.toString() ?? '';
    final favourite = await FavoriteStore.isFavourite(uri);
    if (mounted) {
      setState(() {
        _isFavourite = favourite;
      });
    }
  }

  Future<void> _toggleFavourite(Map<String, dynamic> song) async {
    final uri = song['uri']?.toString() ?? '';
    if (uri.isEmpty) return;
    final newValue = !_isFavourite;
    await FavoriteStore.setFavourite(uri, newValue);
    if (mounted) {
      setState(() {
        _isFavourite = newValue;
      });
    }
  }

  Future<void> _syncFavouriteForSong(Map<String, dynamic> song) async {
    final uri = song['uri']?.toString() ?? '';
    final favourite = await FavoriteStore.isFavourite(uri);
    if (mounted) {
      setState(() {
        _isFavourite = favourite;
      });
    }
  }

// =====================================================
// PLAY SONG
// =====================================================

  Future<void> _playSong(
      int index,
      Map<String, dynamic> song,
      ) async {
    final uri =
        song['uri']?.toString() ?? '';

    if (uri.isEmpty) {
      return;
    }

    try {
      setState(() {
        _currentIndex = index;
        _queuePosition = _queueIndices.indexOf(index);
      });

      widget.onSongChanged(
        index,
        song,
      );

      await _syncFavouriteForSong(song);

      await widget.audioPlayer
          .setAudioSource(
        AudioSource.uri(
          Uri.parse(uri),
        ),
      );

      await _syncAudioSession(widget.audioPlayer);

      await widget.audioPlayer.play();
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context)
          .showSnackBar(
        SnackBar(
          content: Text(
            'Could not play song: $e',
          ),
        ),
      );
    }
  }

// =====================================================
// NEXT
// =====================================================

  Future<void> _nextSong() async {
    final songs = await widget.songsFuture;
    if (songs.isEmpty) return;

// Repeat One: play the same song again.
    if (_repeatMode == LoopMode.one) {
      if (_currentIndex >= 0 && _currentIndex < songs.length) {
        await _playSong(_currentIndex, songs[_currentIndex]);
      }
      return;
    }

// Shuffle: choose a different random song.
    if (_shuffleEnabled) {
      final candidates = _queueIndices.isNotEmpty
          ? List<int>.from(_queueIndices)
          : List<int>.generate(songs.length, (i) => i);

      candidates.remove(_currentIndex);

      if (candidates.isEmpty) {
        return;
      }

      final randomIndex =
      candidates[Random().nextInt(candidates.length)];
      final newQueuePosition =
      _queueIndices.indexOf(randomIndex);

      await _playSong(
        randomIndex,
        songs[randomIndex],
      );

      if (mounted && newQueuePosition >= 0) {
        setState(() {
          _queuePosition = newQueuePosition;
        });
      }
      return;
    }

// Normal / Repeat All playback follows the queue.
    if (_queueIndices.isEmpty) {
      if (_currentIndex >= songs.length - 1) {
        if (_repeatMode == LoopMode.all) {
          await _playSong(0, songs[0]);
        }
        return;
      }

      final nextIndex = _currentIndex + 1;
      await _playSong(nextIndex, songs[nextIndex]);
      return;
    }

    var nextPosition = _queuePosition + 1;

    if (nextPosition >= _queueIndices.length) {
      if (_repeatMode == LoopMode.all) {
        nextPosition = 0;
      } else {
        return;
      }
    }

    if (nextPosition < 0 ||
        nextPosition >= _queueIndices.length) {
      return;
    }

    final nextIndex = _queueIndices[nextPosition];
    if (nextIndex < 0 || nextIndex >= songs.length) return;

    await _playSong(
      nextIndex,
      songs[nextIndex],
    );
  }

// =====================================================
// PREVIOUS
// =====================================================

  Future<void> _previousSong() async {
    final songs = await widget.songsFuture;

    if (_queueIndices.isEmpty) {
      if (_currentIndex <= 0) return;

      final previousIndex = _currentIndex - 1;
      await _playSong(previousIndex, songs[previousIndex]);
      return;
    }

    final previousPosition = _queuePosition - 1;

    if (previousPosition < 0 ||
        previousPosition >= _queueIndices.length) {
      return;
    }

    final previousIndex = _queueIndices[previousPosition];

    if (previousIndex < 0 || previousIndex >= songs.length) return;

    await _playSong(previousIndex, songs[previousIndex]);
  }

// =====================================================
// CURRENT SONG
// =====================================================

  Future<Map<String, dynamic>?>
  _currentSong() async {

    final songs =
    await widget.songsFuture;

    if (_currentIndex < 0 ||
        _currentIndex >= songs.length) {
      return null;
    }

    return songs[_currentIndex];
  }

// =====================================================
// MODE POPUP
// =====================================================

  void _showModePopup(String message, IconData icon) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: Colors.black,
                size: 19,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.white,
          elevation: 4,

// Final wide, short capsule
          margin: const EdgeInsets.only(
            left: 95,
            right: 95,
            bottom: 92,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 7,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
      );
  }

// =====================================================
// FORMAT
// =====================================================

  String _formatDuration(
      Duration duration,
      ) {
    final minutes =
    duration.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');

    final seconds =
    duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');

    return '$minutes:$seconds';
  }

// =====================================================
// BUILD
// =====================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,

      appBar: AppBar(
        backgroundColor: Colors.black,

        leading: IconButton(
          icon: const Icon(
            Icons.keyboard_arrow_down,
            color: Colors.white,
            size: 28,
          ),
          onPressed: () {
            Navigator.pop(context);
          },
        ),

        centerTitle: true,

        actions: const [
          SizedBox(width: 8),
        ],

        title: const Text(
          'NOW PLAYING',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
            color: Colors.white,
          ),
        ),
      ),

      body: FutureBuilder<
          Map<String, dynamic>?>(
        future: _currentSong(),

        builder: (context, snapshot) {

          final song =
              snapshot.data;

          final title =
              song?['title']
                  ?.toString() ??
                  'Nothing playing';

          final artist =
              song?['artist']
                  ?.toString() ??
                  'Unknown Artist';

          final duration =
          song?['duration'] is num
              ? Duration(
            milliseconds:
            (song!['duration']
            as num)
                .toInt(),
          )
              : Duration.zero;

          return SafeArea(
            child: Padding(
              padding:
              const EdgeInsets.symmetric(
                horizontal: 24,
              ),

              child: Column(
                children: [

                  const SizedBox(height: 8),

// =================================================
// ARTWORK
// =================================================

                  Builder(
                    builder: (context) {
                      final widthBasedSize =
                          MediaQuery.of(context).size.width * 0.70;
                      final heightBasedSize =
                          MediaQuery.of(context).size.height * 0.38;
                      final artworkSize = widthBasedSize < heightBasedSize
                          ? widthBasedSize
                          : heightBasedSize;

                      return Container(
                        height: artworkSize,
                        width: artworkSize,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: (song?['artworkPath']?.toString() ?? '').isNotEmpty
                            ? Image.file(
                          File(song!['artworkPath'].toString()),
                          fit: BoxFit.cover,
                          cacheWidth: (artworkSize * 2).round(),
                          filterQuality: FilterQuality.low,
                          errorBuilder: (_, __, ___) {
                            return const Icon(
                              Icons.music_note,
                              color: Colors.black,
                              size: 100,
                            );
                          },
                        )
                            : const Icon(
                          Icons.music_note,
                          color: Colors.black,
                          size: 100,
                        ),
                      );
                    },
                  ),
                  const SizedBox(
                    height: 18,
                  ),

// =================================================
// SONG INFO
// =================================================

                  Row(
                    children: [

                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                          CrossAxisAlignment
                              .start,

                          children: [

                            Text(
                              title,
                              maxLines: 2,
                              overflow:
                              TextOverflow
                                  .ellipsis,

                              style:
                              const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight:
                                FontWeight.bold,
                              ),
                            ),

                            const SizedBox(
                              height: 5,
                            ),

                            Text(
                              artist,
                              maxLines: 1,
                              overflow:
                              TextOverflow
                                  .ellipsis,

                              style:
                              const TextStyle(
                                color:
                                Colors.white54,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),

                      IconButton(
                        tooltip: _isFavourite
                            ? 'Remove from Favourites'
                            : 'Add to Favourites',
                        onPressed: () {
                          if (song != null) {
                            _toggleFavourite(song);
                          }
                        },
                        icon: Icon(
                          _isFavourite
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: _isFavourite
                              ? Colors.red
                              : Colors.white,
                          size: 28,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(
                    height: 22,
                  ),

// =================================================
// PROGRESS
// =================================================

                  StreamBuilder<Duration>(
                    stream: widget
                        .audioPlayer
                        .positionStream,

                    builder:
                        (context, positionSnapshot) {

                      final position =
                          positionSnapshot.data ??
                              Duration.zero;

                      final total =
                          widget.audioPlayer
                              .duration ??
                              duration;

                      final max =
                      total.inMilliseconds
                          .toDouble();

                      final current =
                      position.inMilliseconds
                          .toDouble();

                      final safeMax =
                      max > 0
                          ? max
                          : 1.0;

                      final safeValue =
                      current.clamp(
                        0.0,
                        safeMax,
                      );

                      return Column(
                        children: [

                          SliderTheme(
                            data:
                            SliderTheme.of(
                              context,
                            ).copyWith(
                              activeTrackColor:
                              Colors.white,
                              inactiveTrackColor:
                              Colors.white24,
                              thumbColor:
                              Colors.white,
                              trackHeight: 3,
                              thumbShape:
                              const RoundSliderThumbShape(
                                enabledThumbRadius:
                                5,
                              ),
                            ),

                            child: Slider(
                              value:
                              safeValue,
                              max:
                              safeMax,

                              onChanged:
                              total ==
                                  Duration.zero
                                  ? null
                                  : (value) {
                                widget
                                    .audioPlayer
                                    .seek(
                                  Duration(
                                    milliseconds:
                                    value
                                        .round(),
                                  ),
                                );
                              },
                            ),
                          ),

                          Padding(
                            padding:
                            const EdgeInsets
                                .symmetric(
                              horizontal: 4,
                            ),

                            child: Row(
                              mainAxisAlignment:
                              MainAxisAlignment
                                  .spaceBetween,

                              children: [

                                Text(
                                  _formatDuration(
                                    position,
                                  ),
                                  style:
                                  const TextStyle(
                                    color:
                                    Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),

                                Text(
                                  _formatDuration(
                                    total,
                                  ),
                                  style:
                                  const TextStyle(
                                    color:
                                    Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),

                  const SizedBox(
                    height: 18,
                  ),

// =================================================
// MAIN CONTROLS
// =================================================

                  Row(
                    mainAxisAlignment:
                    MainAxisAlignment.spaceEvenly,
                    children: [

                      IconButton(
                        onPressed: _previousSong,
                        icon: const Icon(
                          Icons.skip_previous,
                          color: Colors.white,
                          size: 38,
                        ),
                      ),

                      StreamBuilder<bool>(
                        stream: widget.audioPlayer.playingStream,
                        builder: (context, snapshot) {
                          final playing = snapshot.data == true;

                          return Container(
                            height: 68,
                            width: 68,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              onPressed: () async {
                                if (playing) {
                                  await widget.audioPlayer.pause();
                                } else {
                                  await widget.audioPlayer.play();
                                }
                              },
                              icon: Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                                color: Colors.black,
                                size: 36,
                              ),
                            ),
                          );
                        },
                      ),

                      IconButton(
                        onPressed: _nextSong,
                        icon: const Icon(
                          Icons.skip_next,
                          color: Colors.white,
                          size: 38,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

// =================================================
// SHUFFLE / QUEUE / REPEAT
// =================================================

                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [

// Shuffle + Queue stacked on the left.
                      Column(
                        children: [
                          IconButton(
                            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                            padding: EdgeInsets.zero,
                            tooltip: 'Shuffle',
                            onPressed: () async {
                              final newValue = !_shuffleEnabled;
                              await widget.audioPlayer
                                  .setShuffleModeEnabled(newValue);
                              if (mounted) {
                                setState(() {
                                  _shuffleEnabled = newValue;
                                });
                              }
                              _showModePopup(
                                newValue ? 'Shuffle All' : 'Shuffle Off',
                                Icons.shuffle,
                              );
                            },
                            icon: Icon(
                              Icons.shuffle,
                              color: _shuffleEnabled
                                  ? Colors.white
                                  : Colors.white54,
                              size: 27,
                            ),
                          ),
                          const Text(
                            'Shuffle',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),

                          const SizedBox(height: 2),

                          IconButton(
                            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                            padding: EdgeInsets.zero,
                            tooltip: 'Queue',
                            onPressed: () async {
                              final updatedQueue =
                              await widget.onOpenQueue?.call();

                              if (!mounted || updatedQueue == null) return;

                              setState(() {
                                _queueIndices = List<int>.from(updatedQueue);
                                _queuePosition =
                                    _queueIndices.indexOf(_currentIndex);
                              });
                            },
                            icon: const Icon(
                              Icons.queue_music,
                              color: Colors.white,
                              size: 27,
                            ),
                          ),
                          const Text(
                            'Queue',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),

// Repeat + Mixer stacked on the right.
                      Column(
                        children: [
                          IconButton(
                            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                            padding: EdgeInsets.zero,
                            tooltip: _repeatMode == LoopMode.one
                                ? 'Repeat one'
                                : _repeatMode == LoopMode.all
                                ? 'Repeat all'
                                : 'Repeat off',
                            onPressed: () async {
                              final LoopMode nextMode;

                              if (_repeatMode == LoopMode.off) {
                                nextMode = LoopMode.all;
                              } else if (_repeatMode == LoopMode.all) {
                                nextMode = LoopMode.one;
                              } else {
                                nextMode = LoopMode.off;
                              }

// Playback order is handled locally below; each song is
// loaded as a single AudioSource.

                              if (mounted) {
                                setState(() {
                                  _repeatMode = nextMode;
                                });
                              }

                              _showModePopup(
                                nextMode == LoopMode.all
                                    ? 'Repeat All'
                                    : nextMode == LoopMode.one
                                    ? 'Repeat One'
                                    : 'Repeat Off',
                                nextMode == LoopMode.one
                                    ? Icons.repeat_one
                                    : Icons.repeat,
                              );
                            },
                            icon: Icon(
                              _repeatMode == LoopMode.one
                                  ? Icons.repeat_one
                                  : Icons.repeat,
                              color: _repeatMode == LoopMode.off
                                  ? Colors.white54
                                  : Colors.white,
                              size: 27,
                            ),
                          ),
                          const Text(
                            'Repeat',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 2),
                          IconButton(
                            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                            padding: EdgeInsets.zero,
                            tooltip: 'Mixer',
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => MixerPage(
                                    audioPlayer: widget.audioPlayer,
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(
                              Icons.tune,
                              color: Colors.white,
                              size: 27,
                            ),
                          ),
                          const Text(
                            'Mixer',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 0),
                ],
              ),
            ),
          );
        },
      ),
    );


  }

// =====================================================
// END HOME PAGE STATE
// =====================================================
}

// =====================================================
// SEARCH PAGE
// =====================================================

class SearchPage extends StatefulWidget {
  final List<Map<String, dynamic>> songs;
  final Future<void> Function(int index) onPlay;
  final MiniPlayerConfig miniPlayer;

  const SearchPage({
    super.key,
    required this.songs,
    required this.onPlay,
    required this.miniPlayer,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<MapEntry<int, Map<String, dynamic>>> _filteredSongs() {
    final query = _query.trim().toLowerCase();

    return widget.songs.asMap().entries.where((entry) {
      if (query.isEmpty) return false;

      final song = entry.value;
      final title = song['title']?.toString().toLowerCase() ?? '';
      final artist = song['artist']?.toString().toLowerCase() ?? '';
      final album = song['album']?.toString().toLowerCase() ?? '';

      return title.contains(query) ||
          artist.contains(query) ||
          album.contains(query);
    }).toList();
  }

  String _displayAlbum(Map<String, dynamic> song) {
    final album = song['album']?.toString().trim() ?? '';
    return album.isEmpty ? 'Unknown Movie' : album;
  }

  @override
  Widget build(BuildContext context) {
    final results = _filteredSongs();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: TextField(
          controller: _searchController,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: (value) {
            setState(() => _query = value);
          },
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: const InputDecoration(
            hintText: 'Search songs, artists or movies',
            hintStyle: TextStyle(color: Colors.white54),
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear, color: Colors.white70),
              onPressed: () {
                _searchController.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
      body: _query.trim().isEmpty
          ? const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search, color: Colors.white30, size: 58),
            SizedBox(height: 12),
            Text(
              'Search your music',
              style: TextStyle(color: Colors.white70, fontSize: 17),
            ),
            SizedBox(height: 5),
            Text(
              'Search by song, artist or movie name',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      )
          : results.isEmpty
          ? const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_off, color: Colors.white30, size: 52),
            SizedBox(height: 10),
            Text(
              'No matching songs found',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ],
        ),
      )
          : ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
        itemCount: results.length,
        separatorBuilder: (_, __) => const Divider(
          color: Colors.white10,
          height: 1,
        ),
        itemBuilder: (context, resultIndex) {
          final entry = results[resultIndex];
          final index = entry.key;
          final song = entry.value;
          final title = song['title']?.toString() ?? 'Unknown title';
          final artist = song['artist']?.toString() ?? 'Unknown Artist';
          final artwork = song['artworkPath']?.toString() ?? '';

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 5),
            leading: _AlbumArtwork(path: artwork, size: 52),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              '$artist • ${_displayAlbum(song)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            trailing: const Icon(
              Icons.play_circle_outline,
              color: Colors.white70,
            ),
            onTap: () => widget.onPlay(index),
          );
        },
      ),
      bottomNavigationBar: SharedMiniPlayer(config: widget.miniPlayer),
    );
  }
}

class ArtistsPage extends StatelessWidget {
  final List<Map<String, dynamic>> songs;
  final Future<void> Function(int index) onPlay;
  final MiniPlayerConfig miniPlayer;

  const ArtistsPage({
    super.key,
    required this.songs,
    required this.onPlay,
    required this.miniPlayer,
  });

  Map<String, List<MapEntry<int, Map<String, dynamic>>>> _groupArtists() {
    final grouped = <String, List<MapEntry<int, Map<String, dynamic>>>>{};

    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      final rawArtist = song['artist']?.toString().trim() ?? '';
      final artist = rawArtist.isEmpty ? 'Unknown Artist' : rawArtist;
      grouped.putIfAbsent(artist, () => []).add(MapEntry(i, song));
    }

    final entries = grouped.entries.toList();
    entries.sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return Map.fromEntries(entries);
  }

  @override
  Widget build(BuildContext context) {
    final artists = _groupArtists();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Artists',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: artists.isEmpty
          ? const Center(
        child: Text(
          'No artists found',
          style: TextStyle(color: Colors.white54),
        ),
      )
          : ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        itemCount: artists.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, artistIndex) {
          final artist = artists.entries.elementAt(artistIndex);
          final artistSongs = artist.value;
          final firstSong = artistSongs.first.value;
          final artwork = firstSong['artworkPath']?.toString() ?? '';

          return InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ArtistSongsPage(
                    artistName: artist.key,
                    songs: artistSongs,
                    onPlay: onPlay,
                    miniPlayer: miniPlayer,
                  ),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF151515),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  _AlbumArtwork(path: artwork, size: 65),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          artist.key,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${artistSongs.length} ${artistSongs.length == 1 ? 'song' : 'songs'}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.white54),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SharedMiniPlayer(config: miniPlayer),
    );
  }
}

class ArtistSongsPage extends StatelessWidget {
  final String artistName;
  final List<MapEntry<int, Map<String, dynamic>>> songs;
  final Future<void> Function(int index) onPlay;
  final MiniPlayerConfig miniPlayer;

  const ArtistSongsPage({
    super.key,
    required this.artistName,
    required this.songs,
    required this.onPlay,
    required this.miniPlayer,
  });

  String _formatDuration(dynamic value) {
    if (value is! num) return '--:--';
    final duration = Duration(milliseconds: value.toInt());
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          artistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        itemCount: songs.length,
        itemBuilder: (context, index) {
          final songEntry = songs[index];
          final song = songEntry.value;
          final artwork = song['artworkPath']?.toString() ?? '';
          final title = song['title']?.toString() ?? 'Unknown Title';
          final album = song['album']?.toString() ?? '';

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            leading: _AlbumArtwork(path: artwork, size: 52),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              album.isEmpty ? artistName : album,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54),
            ),
            trailing: Text(
              _formatDuration(song['duration']),
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            onTap: () => onPlay(songEntry.key),
          );
        },
      ),
      bottomNavigationBar: SharedMiniPlayer(config: miniPlayer),
    );
  }
}

// =====================================================
// GENRES
// =====================================================

class GenresPage extends StatelessWidget {
  final List<Map<String, dynamic>> songs;
  final Future<void> Function(int index) onPlay;
  final MiniPlayerConfig miniPlayer;

  const GenresPage({
    super.key,
    required this.songs,
    required this.onPlay,
    required this.miniPlayer,
  });

  Map<String, List<MapEntry<int, Map<String, dynamic>>>> _groupGenres() {
    final grouped = <String, List<MapEntry<int, Map<String, dynamic>>>>{};

    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      final rawGenre = song['genre']?.toString().trim() ?? '';
      final genre = rawGenre.isEmpty ? 'Unknown Genre' : rawGenre;
      grouped.putIfAbsent(genre, () => []).add(MapEntry(i, song));
    }

    final entries = grouped.entries.toList();
    entries.sort((a, b) {
      if (a.key == 'Unknown Genre') return 1;
      if (b.key == 'Unknown Genre') return -1;
      return a.key.toLowerCase().compareTo(b.key.toLowerCase());
    });

    return Map.fromEntries(entries);
  }

  @override
  Widget build(BuildContext context) {
    final genres = _groupGenres();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Genres',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: genres.isEmpty
          ? const Center(
        child: Text(
          'No genres found',
          style: TextStyle(color: Colors.white54),
        ),
      )
          : ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        itemCount: genres.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, genreIndex) {
          final genre = genres.entries.elementAt(genreIndex);
          final genreSongs = genre.value;

          return InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GenreSongsPage(
                    genreName: genre.key,
                    songs: genreSongs,
                    onPlay: onPlay,
                    miniPlayer: miniPlayer,
                  ),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF151515),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      genre.key == 'Unknown Genre'
                          ? Icons.help_outline
                          : Icons.music_note,
                      color: Colors.black,
                      size: 29,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          genre.key,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${genreSongs.length} ${genreSongs.length == 1 ? 'song' : 'songs'}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SharedMiniPlayer(config: miniPlayer),
    );
  }
}

class GenreSongsPage extends StatelessWidget {
  final String genreName;
  final List<MapEntry<int, Map<String, dynamic>>> songs;
  final Future<void> Function(int index) onPlay;
  final MiniPlayerConfig miniPlayer;

  const GenreSongsPage({
    super.key,
    required this.genreName,
    required this.songs,
    required this.onPlay,
    required this.miniPlayer,
  });

  String _formatDuration(dynamic value) {
    if (value is! num) return '--:--';
    final duration = Duration(milliseconds: value.toInt());
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          genreName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
        children: [
          Container(
            height: 150,
            decoration: BoxDecoration(
              color: const Color(0xFF151515),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  genreName == 'Unknown Genre'
                      ? Icons.help_outline
                      : Icons.music_note,
                  color: Colors.white,
                  size: 52,
                ),
                const SizedBox(height: 10),
                Text(
                  genreName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Container(
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(25),
            ),
            child: TextButton.icon(
              onPressed: songs.isEmpty ? null : () => onPlay(songs.first.key),
              icon: const Icon(Icons.play_arrow, color: Colors.black),
              label: const Text(
                'Play All',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          ...songs.map((songEntry) {
            final song = songEntry.value;
            final title = song['title']?.toString() ?? 'Unknown title';
            final artist = song['artist']?.toString() ?? 'Unknown Artist';
            final artwork = song['artworkPath']?.toString() ?? '';

            return ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 3),
              leading: _AlbumArtwork(path: artwork, size: 52),
              title: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
              ),
              trailing: Text(
                _formatDuration(song['duration']),
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                ),
              ),
              onTap: () => onPlay(songEntry.key),
            );
          }),
        ],
      ),
      bottomNavigationBar: SharedMiniPlayer(config: miniPlayer),
    );
  }
}

// =====================================================
// ALBUMS / MOVIES
// =====================================================

class AlbumsPage extends StatelessWidget {
  final List<Map<String, dynamic>> songs;
  final Future<void> Function(int index) onPlay;
  final MiniPlayerConfig miniPlayer;

  const AlbumsPage({
    super.key,
    required this.songs,
    required this.onPlay,
    required this.miniPlayer,
  });

  Map<String, List<MapEntry<int, Map<String, dynamic>>>> _groupAlbums() {
    final grouped = <String, List<MapEntry<int, Map<String, dynamic>>>>{};

    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      final rawAlbum = song['album']?.toString().trim() ?? '';
      final album = rawAlbum.isEmpty ? 'Unknown Album' : rawAlbum;
      grouped.putIfAbsent(album, () => []).add(MapEntry(i, song));
    }

    final entries = grouped.entries.toList();
    entries.sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return Map.fromEntries(entries);
  }

  @override
  Widget build(BuildContext context) {
    final albums = _groupAlbums();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Albums',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: albums.isEmpty
          ? const Center(
        child: Text(
          'No albums found',
          style: TextStyle(color: Colors.white54),
        ),
      )
          : ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        itemCount: albums.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, albumIndex) {
          final album = albums.entries.elementAt(albumIndex);
          final albumSongs = album.value;
          final firstSong = albumSongs.first.value;
          final artwork = firstSong['artworkPath']?.toString() ?? '';

          return InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AlbumSongsPage(
                    albumName: album.key,
                    songs: albumSongs,
                    onPlay: onPlay,
                    miniPlayer: miniPlayer,
                  ),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF151515),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  _AlbumArtwork(path: artwork, size: 65),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          album.key,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${albumSongs.length} ${albumSongs.length == 1 ? 'song' : 'songs'}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.white54),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SharedMiniPlayer(config: miniPlayer),
    );
  }
}

class AlbumSongsPage extends StatelessWidget {
  final String albumName;
  final List<MapEntry<int, Map<String, dynamic>>> songs;
  final Future<void> Function(int index) onPlay;
  final MiniPlayerConfig miniPlayer;

  const AlbumSongsPage({
    super.key,
    required this.albumName,
    required this.songs,
    required this.onPlay,
    required this.miniPlayer,
  });

  String _formatDuration(dynamic value) {
    if (value is! num) return '--:--';
    final duration = Duration(milliseconds: value.toInt());
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          albumName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
        children: [
          if (songs.isNotEmpty)
            Center(
              child: _AlbumArtwork(
                path: songs.first.value['artworkPath']?.toString() ?? '',
                size: 210,
              ),
            ),
          const SizedBox(height: 18),
          Text(
            albumName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 20),
          Container(
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(25),
            ),
            child: TextButton.icon(
              onPressed: songs.isEmpty ? null : () => onPlay(songs.first.key),
              icon: const Icon(Icons.play_arrow, color: Colors.black),
              label: const Text(
                'Play All',
                style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 18),
          ...songs.map((songEntry) {
            final song = songEntry.value;
            final title = song['title']?.toString() ?? 'Unknown title';
            final artist = song['artist']?.toString() ?? 'Unknown Artist';
            final artwork = song['artworkPath']?.toString() ?? '';
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(vertical: 3),
              leading: _AlbumArtwork(path: artwork, size: 52),
              title: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              trailing: Text(
                _formatDuration(song['duration']),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              onTap: () => onPlay(songEntry.key),
            );
          }),
        ],
      ),
      bottomNavigationBar: SharedMiniPlayer(config: miniPlayer),
    );
  }
}

class _AlbumArtwork extends StatelessWidget {
  final String path;
  final double size;

  const _AlbumArtwork({required this.path, required this.size});

  @override
  Widget build(BuildContext context) {
    final file = path.isNotEmpty ? File(path) : null;
    return Container(
      height: size,
      width: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: file != null
          ? Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: (size * 2).round(),
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) => const Icon(Icons.album, color: Colors.black, size: 38),
      )
          : const Icon(Icons.album, color: Colors.black, size: 38),
    );
  }
}


// =====================================================
// PLAYLISTS
// =====================================================

class PlaylistsPage extends StatefulWidget {
  final List<Map<String, dynamic>> songs;
  final Future<void> Function(List<int> playlistIndices, int selectedIndex)
  onPlayPlaylistSong;
  final MiniPlayerConfig miniPlayer;

  const PlaylistsPage({
    super.key,
    required this.songs,
    required this.onPlayPlaylistSong,
    required this.miniPlayer,
  });

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  late Future<Map<String, List<String>>> _playlistsFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _playlistsFuture = PlaylistStore.getAll();
  }

  Map<String, List<MapEntry<int, Map<String, dynamic>>>> _resolvedPlaylists(
      Map<String, List<String>> playlists,
      ) {
    final byUri = <String, MapEntry<int, Map<String, dynamic>>>{};
    for (var i = 0; i < widget.songs.length; i++) {
      final uri = widget.songs[i]['uri']?.toString() ?? '';
      if (uri.isNotEmpty) {
        byUri[uri] = MapEntry(i, widget.songs[i]);
      }
    }

    final result = <String, List<MapEntry<int, Map<String, dynamic>>>>{};
    playlists.forEach((name, uris) {
      final resolved = <MapEntry<int, Map<String, dynamic>>>[];
      for (final uri in uris) {
        final entry = byUri[uri];
        if (entry != null) resolved.add(entry);
      }
      result[name] = resolved;
    });
    return result;
  }

  Future<void> _createPlaylist() async {
// Keep the dialog completely self-contained. Using a local value instead
// of disposing a TextEditingController immediately after Navigator.pop()
// avoids an Android Flutter framework assertion while the dialog route is
// still being removed.
    String enteredName = '';

    final name = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: const Text(
          'Create Playlist',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          autofocus: true,
          onChanged: (value) => enteredName = value,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) =>
              Navigator.pop(dialogContext, value.trim()),
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, enteredName.trim()),
            child: const Text(
              'Create',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (name == null || name.trim().isEmpty || !mounted) return;

    final created = await PlaylistStore.create(name.trim());
    if (!mounted) return;

    if (!created) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A playlist with this name already exists.'),
        ),
      );
      return;
    }

    _reload();
    setState(() {});
  }

  Future<void> _renamePlaylist(String oldName) async {
    String enteredName = oldName;

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: const Text(
          'Rename Playlist',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          autofocus: true,
          onChanged: (value) => enteredName = value,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) =>
              Navigator.pop(dialogContext, value.trim()),
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: oldName,
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, enteredName.trim()),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (name == null || name.trim().isEmpty || !mounted) return;

    final renamed = await PlaylistStore.rename(oldName, name.trim());
    if (!mounted) return;

    if (!renamed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A playlist with this name already exists.'),
        ),
      );
      return;
    }

    _reload();
    setState(() {});
  }

  Future<void> _deletePlaylist(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: const Text(
          'Delete Playlist?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Delete "$name"? The songs themselves will not be deleted.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await PlaylistStore.delete(name);
    if (mounted) setState(_reload);
  }

  Future<void> _showPlaylistOptions(String name) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white),
              title: const Text('Rename Playlist', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(sheetContext);
                _renamePlaylist(name);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.white),
              title: const Text('Delete Playlist', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(sheetContext);
                _deletePlaylist(name);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Playlists',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        onPressed: _createPlaylist,
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<Map<String, List<String>>>(
        future: _playlistsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }

          final playlists = _resolvedPlaylists(snapshot.data ?? {});

          if (playlists.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.queue_music,
                      color: Colors.white38,
                      size: 64,
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'No playlists yet',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Create a playlist and add your favourite songs.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    TextButton.icon(
                      onPressed: _createPlaylist,
                      icon: const Icon(Icons.add, color: Colors.white),
                      label: const Text(
                        'Create Playlist',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final names = playlists.keys.toList();
          names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 90),
            itemCount: names.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final name = names[index];
              final playlistSongs = playlists[name] ?? [];
              final artwork = playlistSongs.isNotEmpty
                  ? playlistSongs.first.value['artworkPath']?.toString() ?? ''
                  : '';

              return InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PlaylistSongsPage(
                        playlistName: name,
                        songs: widget.songs,
                        initialSongs: playlistSongs,
                        onPlayPlaylistSong: widget.onPlayPlaylistSong,
                        miniPlayer: widget.miniPlayer,
                      ),
                    ),
                  );
                  if (mounted) setState(_reload);
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF151515),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    children: [
                      _AlbumArtwork(path: artwork, size: 65),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '${playlistSongs.length} ${playlistSongs.length == 1 ? 'song' : 'songs'}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        color: const Color(0xFF202020),
                        icon: const Icon(Icons.more_vert, color: Colors.white54),
                        onSelected: (value) {
                          if (value == 'rename') {
                            _renamePlaylist(name);
                          } else if (value == 'delete') {
                            _deletePlaylist(name);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem<String>(
                            value: 'rename',
                            child: Row(
                              children: [
                                Icon(Icons.edit, color: Colors.white, size: 20),
                                SizedBox(width: 12),
                                Text('Rename Playlist', style: TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(Icons.delete_outline, color: Colors.white, size: 20),
                                SizedBox(width: 12),
                                Text('Delete Playlist', style: TextStyle(color: Colors.white)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: SharedMiniPlayer(config: widget.miniPlayer),
    );
  }
}

class PlaylistSongsPage extends StatefulWidget {
  final String playlistName;
  final List<Map<String, dynamic>> songs;
  final List<MapEntry<int, Map<String, dynamic>>> initialSongs;
  final Future<void> Function(List<int> playlistIndices, int selectedIndex)
  onPlayPlaylistSong;
  final MiniPlayerConfig miniPlayer;

  const PlaylistSongsPage({
    super.key,
    required this.playlistName,
    required this.songs,
    required this.initialSongs,
    required this.onPlayPlaylistSong,
    required this.miniPlayer,
  });

  @override
  State<PlaylistSongsPage> createState() => _PlaylistSongsPageState();
}

class _PlaylistSongsPageState extends State<PlaylistSongsPage> {
  late List<MapEntry<int, Map<String, dynamic>>> _playlistSongs;

  @override
  void initState() {
    super.initState();
    _playlistSongs = List<MapEntry<int, Map<String, dynamic>>>.from(
      widget.initialSongs,
    );
  }

  Future<void> _reloadSongs() async {
    final playlists = await PlaylistStore.getAll();
    final uris = playlists[widget.playlistName] ?? [];
    final byUri = <String, MapEntry<int, Map<String, dynamic>>>{};

    for (var i = 0; i < widget.songs.length; i++) {
      final uri = widget.songs[i]['uri']?.toString() ?? '';
      if (uri.isNotEmpty) byUri[uri] = MapEntry(i, widget.songs[i]);
    }

    final resolved = <MapEntry<int, Map<String, dynamic>>>[];
    for (final uri in uris) {
      final entry = byUri[uri];
      if (entry != null) resolved.add(entry);
    }

    if (mounted) {
      setState(() => _playlistSongs = resolved);
    }
  }

  List<int> get _playlistIndices =>
      _playlistSongs.map((entry) => entry.key).toList();

  Future<void> _addSongs() async {
    final playlists = await PlaylistStore.getAll();
    final currentUris = (playlists[widget.playlistName] ?? []).toSet();
    final selectedUris = <String>{...currentUris};

    final added = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF171717),
              title: const Text(
                'Add Songs',
                style: TextStyle(color: Colors.white),
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: MediaQuery.of(context).size.height * 0.55,
                child: widget.songs.isEmpty
                    ? const Center(
                  child: Text(
                    'No songs found',
                    style: TextStyle(color: Colors.white54),
                  ),
                )
                    : ListView.builder(
                  itemCount: widget.songs.length,
                  itemBuilder: (context, index) {
                    final song = widget.songs[index];
                    final uri = song['uri']?.toString() ?? '';
                    final title = song['title']?.toString() ?? 'Unknown title';
                    final artist = song['artist']?.toString() ?? 'Unknown Artist';
                    final checked = uri.isNotEmpty && selectedUris.contains(uri);

                    return CheckboxListTile(
                      value: checked,
                      onChanged: uri.isEmpty
                          ? null
                          : (value) {
                        setDialogState(() {
                          if (value == true) {
                            selectedUris.add(uri);
                          } else {
                            selectedUris.remove(uri);
                          }
                        });
                      },
                      activeColor: Colors.white,
                      checkColor: Colors.black,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Done', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );

    if (added != true) return;

    await PlaylistStore.addSongs(
      widget.playlistName,
      selectedUris.toList(),
    );
    await _reloadSongs();
  }

  Future<void> _removeSong(MapEntry<int, Map<String, dynamic>> entry) async {
    final uri = entry.value['uri']?.toString() ?? '';
    if (uri.isEmpty) return;

    await PlaylistStore.removeSong(widget.playlistName, uri);
    await _reloadSongs();
  }

  Future<void> _reorderSongs(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    setState(() {
      final movedSong = _playlistSongs.removeAt(oldIndex);
      _playlistSongs.insert(newIndex, movedSong);
    });

    final uris = _playlistSongs
        .map((entry) => entry.value['uri']?.toString() ?? '')
        .where((uri) => uri.isNotEmpty)
        .toList();

    await PlaylistStore.reorderSongs(widget.playlistName, uris);
  }

  Future<void> _renamePlaylistFromPage() async {
    String enteredName = widget.playlistName;

    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: const Text('Rename Playlist', style: TextStyle(color: Colors.white)),
        content: TextField(
          autofocus: true,
          onChanged: (value) => enteredName = value,
          textInputAction: TextInputAction.done,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: InputDecoration(
            hintText: widget.playlistName,
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, enteredName.trim()),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (name == null || name.trim().isEmpty || !mounted) return;
    final renamed = await PlaylistStore.rename(widget.playlistName, name.trim());
    if (!mounted) return;
    if (!renamed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A playlist with this name already exists.')),
      );
      return;
    }

    Navigator.pop(context);
  }

  Future<void> _deletePlaylistFromPage() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        title: const Text('Delete Playlist?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Delete "${widget.playlistName}"? The songs themselves will not be deleted.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await PlaylistStore.delete(widget.playlistName);
    if (mounted) Navigator.pop(context);
  }

  String _formatDuration(dynamic value) {
    if (value is! num) return '--:--';
    final duration = Duration(milliseconds: value.toInt());
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.playlistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Add songs',
            onPressed: _addSongs,
            icon: const Icon(Icons.add),
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'rename') {
                await _renamePlaylistFromPage();
              } else if (value == 'delete') {
                await _deletePlaylistFromPage();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'rename',
                child: Text('Rename Playlist'),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Text('Delete Playlist'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
        children: [
          if (_playlistSongs.isNotEmpty)
            Center(
              child: _AlbumArtwork(
                path: _playlistSongs.first.value['artworkPath']?.toString() ?? '',
                size: 210,
              ),
            )
          else
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 18),
                child: Icon(Icons.queue_music, color: Colors.white38, size: 90),
              ),
            ),
          const SizedBox(height: 18),
          Text(
            widget.playlistName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '${_playlistSongs.length} ${_playlistSongs.length == 1 ? 'song' : 'songs'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 50,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(25),
                  ),
                  child: TextButton.icon(
                    onPressed: _playlistSongs.isEmpty
                        ? null
                        : () => widget.onPlayPlaylistSong(
                      _playlistIndices,
                      _playlistIndices.first,
                    ),
                    icon: const Icon(Icons.play_arrow, color: Colors.black),
                    label: const Text(
                      'Play All',
                      style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Container(
                height: 50,
                width: 50,
                decoration: BoxDecoration(
                  color: const Color(0xFF171717),
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(color: Colors.white12),
                ),
                child: IconButton(
                  tooltip: 'Add songs',
                  onPressed: _addSongs,
                  icon: const Icon(Icons.add, color: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_playlistSongs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(
                child: Text(
                  'This playlist is empty.\nTap + to add songs.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, height: 1.5),
                ),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _playlistSongs.length,
              onReorder: _reorderSongs,
              itemBuilder: (context, index) {
                final songEntry = _playlistSongs[index];
                final song = songEntry.value;
                final title = song['title']?.toString() ?? 'Unknown title';
                final artist = song['artist']?.toString() ?? 'Unknown Artist';
                final artwork = song['artworkPath']?.toString() ?? '';
                final uri = song['uri']?.toString() ?? '';

                return ListTile(
                  key: ValueKey(uri.isNotEmpty ? uri : '${songEntry.key}_$index'),
                  contentPadding: const EdgeInsets.symmetric(vertical: 3),
                  leading: _AlbumArtwork(path: artwork, size: 52),
                  title: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatDuration(song['duration']),
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      PopupMenuButton<String>(
                        color: const Color(0xFF202020),
                        icon: const Icon(Icons.more_vert, color: Colors.white54),
                        onSelected: (value) {
                          if (value == 'remove') {
                            _removeSong(songEntry);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem<String>(
                            value: 'remove',
                            child: Row(
                              children: [
                                Icon(Icons.remove_circle_outline, color: Colors.white, size: 20),
                                SizedBox(width: 12),
                                Text(
                                  'Remove from Playlist',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.only(left: 4),
                          child: Icon(Icons.drag_handle, color: Colors.white54),
                        ),
                      ),
                    ],
                  ),
                  onTap: () => widget.onPlayPlaylistSong(
                    _playlistIndices,
                    songEntry.key,
                  ),
                );
              },
            ),
        ],
      ),
      bottomNavigationBar: SharedMiniPlayer(config: widget.miniPlayer),);
  }
}

// =====================================================
// MIXER
// =====================================================

class MixerPage extends StatefulWidget {
  final AudioPlayer audioPlayer;

  const MixerPage({
    super.key,
    required this.audioPlayer,
  });

  @override
  State<MixerPage> createState() => _MixerPageState();
}

class _MixerPageState extends State<MixerPage> {
  final List<String> _presets = const [
    'Normal',
    'Bass',
    'Rock',
    'Pop',
    'Classical',
    'Vocal',
  ];

  int _selectedPreset = 0;
  double _bassBoost = 0;
  double _virtualizer = 0;
  List<double> _bands = List<double>.filled(7, 0);

  bool _nativeEffectsAvailable = false;
  StreamSubscription<int?>? _audioSessionSubscription;
  AndroidEqualizerParameters? _equalizerParameters;

  static const String _mixerPresetKey = 'mixer_selected_preset';
  static const String _mixerBassBoostKey = 'mixer_bass_boost';
  static const String _mixerVirtualizerKey = 'mixer_virtualizer';
  static const String _mixerBandsKey = 'mixer_eq_bands';

  @override
  void initState() {
    super.initState();

// just_audio can create/update the Android audio session only after
// playback has been initialized. Listen for the real session ID so the
// native mixer is attached to the actual player output.
    _audioSessionSubscription =
        widget.audioPlayer.androidAudioSessionIdStream.listen((sessionId) async {
          if (sessionId == null || sessionId <= 0) return;

          try {
// A new Android audio session can expose a fresh set of EQ band
// objects. Never keep stale band objects from the old session.
            _equalizerParameters = null;

            await _audioMixerChannel.invokeMethod(
              'setAudioSessionId',
              {'sessionId': sessionId},
            );

            final info =
            await _audioMixerChannel.invokeMethod('getEqualizerInfo');

            if (!mounted) return;
            setState(() {
              _nativeEffectsAvailable =
                  info is Map && info['available'] == true;
            });

// The just_audio equalizer follows the player pipeline automatically.
// Re-apply the current EQ values after a session recreation.
            await _applyCurrentSettings();
          } catch (e) {
            debugPrint('AUDIO SESSION MIXER ERROR: $e');
          }
        });

    _initializeMixer();
  }

  Future<void> _initializeMixer() async {
    await _loadMixerSettings();
    await _connectMixer();
  }

  Future<void> _loadMixerSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedBands = prefs.getStringList(_mixerBandsKey);
      var loadedBands = List<double>.filled(7, 0);
      if (savedBands != null && savedBands.length == 7) {
        final parsed = savedBands.map((value) => double.tryParse(value)).toList();
        if (parsed.every((value) => value != null)) {
          loadedBands = parsed.cast<double>();
        }
      }
      final loadedPreset = prefs.getInt(_mixerPresetKey) ?? 0;
      final loadedBass = prefs.getDouble(_mixerBassBoostKey) ?? 0;
      final loadedVirtualizer = prefs.getDouble(_mixerVirtualizerKey) ?? 0;
      if (!mounted) return;
      setState(() {
        _selectedPreset = loadedPreset.clamp(0, _presets.length - 1).toInt();
        _bassBoost = loadedBass.clamp(0, 100).toDouble();
        _virtualizer = loadedVirtualizer.clamp(0, 100).toDouble();
        _bands = loadedBands;
      });
    } catch (e) {
      debugPrint('MIXER SETTINGS LOAD ERROR: $e');
    }
  }

  Future<void> _saveMixerSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_mixerPresetKey, _selectedPreset);
      await prefs.setDouble(_mixerBassBoostKey, _bassBoost);
      await prefs.setDouble(_mixerVirtualizerKey, _virtualizer);
      await prefs.setStringList(_mixerBandsKey, _bands.map((value) => value.toString()).toList());
    } catch (e) {
      debugPrint('MIXER SETTINGS SAVE ERROR: $e');
    }
  }

  Future<void> _connectMixer() async {
    try {
      await _androidEqualizer.setEnabled(true);
      _equalizerParameters = await _androidEqualizer.parameters;
    } catch (e) {
      debugPrint('JUST AUDIO EQ ERROR: $e');
    }

    final sessionId = widget.audioPlayer.androidAudioSessionId;
    if (sessionId != null && sessionId > 0) {
      try {
        await _audioMixerChannel.invokeMethod(
          'setAudioSessionId',
          {'sessionId': sessionId},
        );
      } catch (e) {
        debugPrint('AUDIO SESSION CONNECT ERROR: $e');
      }
    }

    try {
      final info = await _audioMixerChannel.invokeMethod('getEqualizerInfo');
      if (!mounted) return;
      setState(() {
        _nativeEffectsAvailable = info is Map && info['available'] == true;
      });
      await _applyCurrentSettings();
    } catch (e) {
      debugPrint('MIXER INFO ERROR: $e');
    }
  }

  @override
  void dispose() {
    _audioSessionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _setEqualizerBand(int band, double value) async {
    try {
      await _androidEqualizer.setEnabled(true);
      final parameters =
      _equalizerParameters ??= await _androidEqualizer.parameters;
      if (parameters.bands.isEmpty ||
          band < 0 ||
          band >= _mixerFrequenciesHz.length) {
        return;
      }

// Android devices can expose a different number of native EQ bands.
// Use the bands actually supplied by just_audio and map our UI
// frequencies to the closest available native band.

      final targetFrequency = _mixerFrequenciesHz[band];
      final nativeBand = parameters.bands.reduce(
            (a, b) =>
        (a.centerFrequency - targetFrequency).abs() <=
            (b.centerFrequency - targetFrequency).abs()
            ? a
            : b,
      );

// Bass Boost is also reinforced through the already-working
// just_audio Equalizer. This makes Bass Boost audible even on
// Android devices whose native BassBoost implementation is a no-op.
      double effectiveValue = value;
      if (band == 0) {
        effectiveValue += (_bassBoost * 0.08);
      } else if (band == 1) {
        effectiveValue += (_bassBoost * 0.05);
      } else if (band == 2) {
        effectiveValue += (_bassBoost * 0.02);
      }

// Android 15 deprecated the legacy Virtualizer API. Keep a subtle
// spatial-style EQ fallback so the Virtualizer slider still has an
// audible effect on devices where the native effect is unavailable.
      const virtualizerCurve = <double>[
        0.5, 0.0, -0.8, -1.2, 0.8, 1.8, 2.2,
      ];
      effectiveValue += virtualizerCurve[band] * (_virtualizer / 100.0);

      final gain = effectiveValue
          .clamp(parameters.minDecibels, parameters.maxDecibels)
          .toDouble();
      await nativeBand.setGain(gain);
    } catch (e) {
      debugPrint('EQ BAND ERROR: $e');
    }
  }

  Future<void> _setBassBoost(double value) async {
    try {
      final result = await _audioMixerChannel.invokeMethod('setBassBoost', {
        'strength': (value * 10).round(),
        'enabled': value > 0,
      });

// Keep the audible bass response tied to the EQ that is already
// proven to work with this player's AudioPipeline.
      await _applyEqualizerSettings();

      if (result == false) {
        debugPrint('NATIVE BASS BOOST UNAVAILABLE - EQ BASS FALLBACK ACTIVE');
      }
    } catch (e) {
      debugPrint('BASS BOOST ERROR: $e');
      await _applyEqualizerSettings();
    }
  }

  Future<void> _setVirtualizer(double value) async {
    try {
      final result = await _audioMixerChannel.invokeMethod('setVirtualizer', {
        'strength': (value * 10).round(),
        'enabled': value > 0,
      });

// Also update the spatial-style EQ fallback described above.
      await _applyEqualizerSettings();

      if (result == false) {
        debugPrint('NATIVE VIRTUALIZER UNAVAILABLE - EQ SPATIAL FALLBACK ACTIVE');
      }
    } catch (e) {
      debugPrint('VIRTUALIZER ERROR: $e');
      await _applyEqualizerSettings();
    }
  }

  Future<void> _applyEqualizerSettings() async {
    for (var i = 0; i < _bands.length; i++) {
      await _setEqualizerBand(i, _bands[i]);
    }
  }

  Future<void> _applyCurrentSettings() async {
    await _applyEqualizerSettings();
    await _setBassBoost(_bassBoost);
    await _setVirtualizer(_virtualizer);
  }

  Future<void> _selectPreset(int index) async {
    setState(() {
      _selectedPreset = index;
      switch (index) {
        case 1:
          _bands = [6, 5, 3, 1, 0, -1, -2];
          _bassBoost = 75;
          _virtualizer = 20;
          break;
        case 2:
          _bands = [4, 2, 0, -1, 2, 4, 5];
          _bassBoost = 35;
          _virtualizer = 45;
          break;
        case 3:
          _bands = [3, 4, 2, 0, 1, 3, 4];
          _bassBoost = 45;
          _virtualizer = 35;
          break;
        case 4:
          _bands = [3, 1, -2, -1, 2, 4, 3];
          _bassBoost = 20;
          _virtualizer = 55;
          break;
        case 5:
          _bands = [-2, -1, 1, 3, 4, 3, 1];
          _bassBoost = 15;
          _virtualizer = 30;
          break;
        default:
          _bands = List<double>.filled(7, 0);
          _bassBoost = 0;
          _virtualizer = 0;
      }
    });

    await _saveMixerSettings();
    await _applyCurrentSettings();
  }

  Future<void> _reset() async {
    setState(() {
      _selectedPreset = 0;
      _bassBoost = 0;
      _virtualizer = 0;
      _bands = List<double>.filled(7, 0);
    });

    await _saveMixerSettings();
    await _applyCurrentSettings();
  }

  @override
  Widget build(BuildContext context) {
    const frequencies = ['60', '150', '400', '1K', '2.4K', '6K', '14K'];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Mixer',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          TextButton(
            onPressed: _reset,
            child: const Text(
              'Reset',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          children: [
            const Text(
              'Presets',
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _presets.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final selected = index == _selectedPreset;
                  return ChoiceChip(
                    label: Text(_presets[index]),
                    selected: selected,
                    onSelected: (_) => _selectPreset(index),
                    backgroundColor: const Color(0xFF171717),
                    selectedColor: Colors.white,
                    labelStyle: TextStyle(
                      color: selected ? Colors.black : Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                    side: const BorderSide(color: Colors.white12),
                  );
                },
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              'Equalizer',
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 18),
            Container(
              height: 250,
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
              decoration: BoxDecoration(
                color: const Color(0xFF111111),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: List.generate(_bands.length, (index) {
                  return Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: RotatedBox(
                            quarterTurns: 3,
                            child: Slider(
                              value: _bands[index],
                              min: -12,
                              max: 12,
                              activeColor: Colors.white,
                              inactiveColor: Colors.white24,
                              onChanged: (value) {
                                setState(() {
                                  _bands[index] = value;
                                  _selectedPreset = 0;
                                });
                                _saveMixerSettings();
                                _setEqualizerBand(index, value);
                              },
                            ),
                          ),
                        ),
                        Text(
                          frequencies[index],
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              ),
            ),
            const SizedBox(height: 26),
            _effectSlider(
              title: 'Bass Boost',
              value: _bassBoost,
              onChanged: (value) {
                setState(() {
                  _bassBoost = value;
                  _selectedPreset = 0;
                });
                _saveMixerSettings();
                _setBassBoost(value);
              },
            ),
            const SizedBox(height: 14),
            _effectSlider(
              title: 'Virtualizer',
              value: _virtualizer,
              onChanged: (value) {
                setState(() {
                  _virtualizer = value;
                  _selectedPreset = 0;
                });
                _saveMixerSettings();
                _setVirtualizer(value);
              },
            ),
            const SizedBox(height: 24),
            if (!_nativeEffectsAvailable)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF151515),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.white54, size: 19),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Native audio effects are not available for the current audio session on this device.',
                        style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.35),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _effectSlider({
    required String title,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${value.round()}%',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          Slider(
            value: value,
            min: 0,
            max: 100,
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// =====================================================
// DUPLICATE CLEANER
// =====================================================

class DuplicateCleanerPage extends StatefulWidget {
  final List<Map<String, dynamic>> songs;

  const DuplicateCleanerPage({super.key, required this.songs});

  @override
  State<DuplicateCleanerPage> createState() => _DuplicateCleanerPageState();
}

class _DuplicateCleanerPageState extends State<DuplicateCleanerPage> {
  late List<Map<String, dynamic>> _songs;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _songs = List<Map<String, dynamic>>.from(widget.songs);
  }

  String _clean(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'\.(mp3|m4a|aac|wav|flac|ogg|opus)$'), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  String _duplicateKey(Map<String, dynamic> song) {
    final title = _clean(song['title']?.toString() ?? '');
    final artist = _clean(song['artist']?.toString() ?? '');
    final duration = song['duration'] is num
        ? (song['duration'] as num).toInt()
        : 0;
    // A 3-second bucket avoids missing the same file when scanner metadata
    // differs by a tiny amount between copies.
    final durationBucket = duration > 0 ? (duration / 3000).round() : 0;
    return '$title|$artist|$durationBucket';
  }

  List<List<Map<String, dynamic>>> _duplicateGroups() {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final song in _songs) {
      final key = _duplicateKey(song);
      if (key.startsWith('|')) continue;
      grouped.putIfAbsent(key, () => []).add(song);
    }
    return grouped.values.where((group) => group.length > 1).toList();
  }

  String _formatDuration(dynamic value) {
    final ms = value is num ? value.toInt() : 0;
    final duration = Duration(milliseconds: ms);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${duration.inHours}:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<bool> _deleteSong(Map<String, dynamic> song) async {
    final uri = song['uri']?.toString() ?? '';
    if (uri.isEmpty) return false;

    try {
      // MainActivity handles MediaStore/content:// deletion and any Android
      // confirmation required by the OS.
      final result = await _musicChannel.invokeMethod<bool>(
        'deleteSong',
        {'uri': uri},
      );
      return result == true;
    } on PlatformException catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message ?? 'Unable to delete this song.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    } on MissingPluginException {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Delete support is not connected in MainActivity yet.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return false;
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> song) async {
    if (_deleting) return;

    final title = song['title']?.toString() ?? 'Unknown title';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF151515),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'Delete song?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Text(
          '"$title" will be removed from your device. This cannot be undone.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    final deleted = await _deleteSong(song);
    if (!mounted) return;

    if (deleted) {
      final uri = song['uri']?.toString() ?? '';
      setState(() {
        _songs.removeWhere((item) => item['uri']?.toString() == uri);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Song deleted successfully'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    setState(() => _deleting = false);
  }

  Widget _artwork(String path) {
    final file = path.isNotEmpty ? File(path) : null;
    return Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: file == null
          ? const Icon(Icons.music_note, color: Colors.white54)
          : Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: 116,
        filterQuality: FilterQuality.low,
        errorBuilder: (_, __, ___) =>
        const Icon(Icons.music_note, color: Colors.white54),
      ),
    );
  }

  Widget _songRow(Map<String, dynamic> song) {
    final title = song['title']?.toString() ?? 'Unknown title';
    final artist = song['artist']?.toString() ?? 'Unknown Artist';
    final artwork = song['artworkPath']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        leading: _artwork(artwork),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _formatDuration(song['duration']),
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            PopupMenuButton<String>(
              color: const Color(0xFF202020),
              icon: const Icon(Icons.more_vert, color: Colors.white54),
              onSelected: (value) {
                if (value == 'delete') _confirmDelete(song);
              },
              itemBuilder: (_) => const [
                PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                      SizedBox(width: 10),
                      Text('Delete Song', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _duplicateGroups();
    final duplicateCount = groups.fold<int>(0, (sum, group) => sum + group.length);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Duplicate Cleaner',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _songs.isEmpty
          ? const Center(
        child: Text('No songs found', style: TextStyle(color: Colors.white54)),
      )
          : groups.isEmpty
          ? const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, color: Colors.white54, size: 54),
            SizedBox(height: 14),
            Text(
              'No duplicate songs found',
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 6),
            Text(
              'Your music library is clean.',
              style: TextStyle(color: Colors.white54),
            ),
          ],
        ),
      )
          : ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF151515),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: [
                const Icon(Icons.library_music_outlined, color: Color(0xFF2196F3), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$duplicateCount duplicate songs',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${groups.length} duplicate ${groups.length == 1 ? 'group' : 'groups'} found',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ...groups.asMap().entries.map((entry) {
            final group = entry.value;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    'Duplicate group ${entry.key + 1}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                ...group.map(_songRow),
                const SizedBox(height: 12),
              ],
            );
          }),
        ],
      ),
    );
  }
}