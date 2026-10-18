import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
void main() {
  runApp(const MusicPlayerApp());
}

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Music Player',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(
          primary: Colors.black,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // =========================
      // APP BAR
      // =========================
      appBar: AppBar(
        title: const Text(
          'Music Player',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
            color: Colors.black,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.search,
              color: Colors.black,
            ),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(
              Icons.settings_outlined,
              color: Colors.black,
            ),
            onPressed: () {},
          ),
        ],
      ),

      // =========================
      // HOME PAGE
      // =========================
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          20,
          10,
          20,
          30,
        ),
        children: [

          // =========================
          // LIBRARY
          // =========================
          const Text(
            'Library',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 15),

          Row(
            children: [
              _category(
                Icons.music_note,
                'Songs',
              ),
              _category(
                Icons.album_outlined,
                'Albums',
              ),
              _category(
                Icons.queue_music,
                'Playlists',
              ),
              _category(
                Icons.favorite_border,
                'Favourites',
              ),
            ],
          ),

          const SizedBox(height: 30),

          // =========================
          // LAST PLAYED
          // =========================
          Row(
            mainAxisAlignment:
                MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Last Played',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextButton(
                onPressed: () {},
                child: const Text(
                  'See all',
                  style: TextStyle(
                    color: Colors.black,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 5),

          _songTile(
            context,
            'No songs played yet',
            'Your recently played songs will appear here',
            Icons.music_note,
          ),

          const SizedBox(height: 25),

          // =========================
          // SONGS
          // =========================
          const Text(
            'Songs',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 10),

          _scannedSongs(),

          const SizedBox(height: 25),

          // =========================
          // SMART FEATURES
          // =========================
          const Text(
            'Smart Features',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 12),

          _featureTile(
            Icons.auto_awesome,
            'Auto DJ',
            'Create a smart queue from your music',
          ),

          _featureTile(
            Icons.mood_outlined,
            'Mood Playlists',
            'Discover music based on your mood',
          ),

          _featureTile(
            Icons.library_music_outlined,
            'Duplicate Cleaner',
            'Find duplicate music files',
          ),
        ],
      ),

      // =========================
      // MINI PLAYER
      // =========================
      bottomNavigationBar: const MiniPlayer(),
    );
  }
// =========================
  // MUSIC SCANNER
  // =========================
  static Future<List<Map<String, dynamic>>> _loadSongs() async {
    const MethodChannel channel = MethodChannel('music_scanner');

    try {
      final List<dynamic> result =
      await channel.invokeMethod('scanMusic');

      final songs = result
          .map(
            (song) => Map<String, dynamic>.from(song as Map),
      )
          .toList();

      debugPrint('NATIVE MUSIC COUNT = ${songs.length}');

      return songs;
    } catch (e) {
      debugPrint('NATIVE MUSIC ERROR = $e');
      return [];
    }
  }

  static Widget _scannedSongs() {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _loadSongs(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: SizedBox(
              height: 55,
              width: 55,
              child: Center(
                child: CircularProgressIndicator(
                  color: Colors.black,
                ),
              ),
            ),
            title: Text(
              'Scanning music...',
              style: TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              'Finding songs on your device',
            ),
          );
        }

        if (snapshot.hasError) {
          return const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.error_outline,
              color: Colors.black,
            ),
            title: Text(
              'Unable to scan music',
              style: TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }

        final songs = snapshot.data ?? [];

        if (songs.isEmpty) {
          return const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.music_off,
              color: Colors.black,
            ),
            title: Text(
              'No music found',
              style: TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              'No audio files were found on your device',
            ),
          );
        }

        return Column(
          children: songs.map((song) {
            return _songTile(
              context,
              song['title']?.toString() ?? 'Unknown title',
              song['artist']?.toString() ?? 'Unknown artist',
              Icons.music_note,
            );
          }).toList(),
        );
      },
    );
  }
  // =========================
  // CATEGORY BUTTON
  // =========================
  static Widget _category(
    IconData icon,
    String title,
  ) {
    return Expanded(
      child: Column(
        children: [
          Container(
            height: 58,
            width: 58,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: 27,
            ),
          ),

          const SizedBox(height: 8),

          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // =========================
  // SONG TILE
  // =========================
  static Widget _songTile(
    BuildContext context,
    String title,
    String subtitle,
    IconData icon,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,

      leading: Container(
        height: 55,
        width: 55,
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
          icon,
          color: Colors.black,
        ),
      ),

      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
        ),
      ),

      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),

      trailing: const Icon(
        Icons.more_vert,
        color: Colors.black,
      ),

      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Music scanning will be added next.',
            ),
          ),
        );
      },
    );
  }

  // =========================
  // SMART FEATURE TILE
  // =========================
  static Widget _featureTile(
    IconData icon,
    String title,
    String subtitle,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.zero,

      leading: Container(
        height: 50,
        width: 50,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          icon,
          color: Colors.white,
        ),
      ),

      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
        ),
      ),

      subtitle: Text(subtitle),

      trailing: const Icon(
        Icons.chevron_right,
        color: Colors.black,
      ),
    );
  }
}

// =====================================================
// MINI PLAYER
// =====================================================

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,

      padding: const EdgeInsets.symmetric(
        horizontal: 14,
      ),

      decoration: BoxDecoration(
        color: Colors.white,

        border: Border(
          top: BorderSide(
            color: Colors.grey.shade300,
          ),
        ),
      ),

      child: Row(
        children: [

          // =========================
          // ALBUM ART
          // =========================
          Container(
            height: 52,
            width: 52,

            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
            ),

            child: const Icon(
              Icons.music_note,
              color: Colors.white,
              size: 26,
            ),
          ),

          const SizedBox(width: 12),

          // =========================
          // SONG INFORMATION
          // =========================
          const Expanded(
            child: Column(
              mainAxisAlignment:
                  MainAxisAlignment.center,

              crossAxisAlignment:
                  CrossAxisAlignment.start,

              children: [

                Text(
                  'Nothing playing',
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,

                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                    fontSize: 14,
                  ),
                ),

                SizedBox(height: 3),

                Text(
                  'Select a song to play',
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,

                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // =========================
          // PREVIOUS
          // =========================
          IconButton(
            onPressed: () {},
            icon: const Icon(
              Icons.skip_previous,
              color: Colors.black,
            ),
          ),

          // =========================
          // PLAY
          // =========================
          Container(
            height: 42,
            width: 42,

            decoration:
                const BoxDecoration(
              color: Colors.black,
              shape: BoxShape.circle,
            ),

            child: IconButton(
              onPressed: () {},
              icon: const Icon(
                Icons.play_arrow,
                color: Colors.white,
                size: 23,
              ),
            ),
          ),

          // =========================
          // NEXT
          // =========================
          IconButton(
            onPressed: () {},
            icon: const Icon(
              Icons.skip_next,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}