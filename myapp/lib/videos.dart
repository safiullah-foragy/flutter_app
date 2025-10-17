import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

class VideosPage extends StatefulWidget {
  const VideosPage({super.key});

  @override
  State<VideosPage> createState() => _VideosPageState();
}

class _VideosPageState extends State<VideosPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  // List is provided by a StreamBuilder below; no local cache needed

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Videos')),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('posts')
            .where('video_url', isGreaterThan: '')
            .snapshots(includeMetadataChanges: true),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = List<QueryDocumentSnapshot>.from(snapshot.data!.docs);
          // Newest first by timestamp if available
          docs.sort((a, b) {
            final ad = (a.data() as Map<String, dynamic>?); 
            final bd = (b.data() as Map<String, dynamic>?);
            final at = ad?['timestamp'];
            final bt = bd?['timestamp'];
            int ai = at is int ? at : (at is Timestamp ? at.millisecondsSinceEpoch : 0);
            int bi = bt is int ? bt : (bt is Timestamp ? bt.millisecondsSinceEpoch : 0);
            return bi.compareTo(ai);
          });
          final videos = docs.map((d) {
            final data = d.data() as Map<String, dynamic>?;
            return {'id': d.id, ...?data};
          }).toList();

          if (videos.isEmpty) {
            return const Center(child: Text('No videos'));
          }

          return ListView.builder(
            itemCount: videos.length,
            itemBuilder: (context, index) {
              final v = videos[index];
              final url = (v['video_url'] as String?) ?? '';
              return ListTile(
                title: Text(v['text'] ?? 'Video'),
                subtitle: Text(v['user_id'] ?? ''),
                onTap: () {
                  if (url.isNotEmpty) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => VideoPlayerScreen(
                          videos: videos,
                          startIndex: index,
                        ),
                      ),
                    );
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}
class VideoPlayerScreen extends StatefulWidget {
  final List<Map<String, dynamic>> videos;
  final int startIndex;

  const VideoPlayerScreen({super.key, required this.videos, required this.startIndex});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  VideoPlayerController? _vController;
  ChewieController? _chewieController;
  late int _index;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _index = widget.startIndex;
    _loadAtIndex(_index);
  }

  Future<void> _loadAtIndex(int idx) async {
    setState(() {
      _loading = true;
      _error = false;
    });

    // dispose previous
    try {
      _chewieController?.dispose();
    } catch (_) {}
    try {
      _vController?.dispose();
    } catch (_) {}
    _chewieController = null;
    _vController = null;

    final url = (widget.videos[idx]['video_url'] as String?) ?? '';
    if (url.isEmpty) {
      setState(() {
        _error = true;
        _loading = false;
      });
      return;
    }

    try {
      _vController = VideoPlayerController.networkUrl(Uri.parse(url));
      await _vController!.initialize();
      _chewieController = ChewieController(
        videoPlayerController: _vController!,
        autoPlay: true,
        looping: false,
        allowMuting: true,
      );

      // listen for end
      _vController!.addListener(() {
        final controller = _vController!;
        if (!controller.value.isInitialized) return;
        final position = controller.value.position;
        final duration = controller.value.duration;
        // position and duration are non-null when initialized; check if we've reached the end
        if (duration.inMilliseconds > 0 && position >= duration && !controller.value.isPlaying) {
          _playNext();
        }
      });

      setState(() {
        _loading = false;
        _error = false;
      });
    } catch (e) {
      print('Video init error for $url: $e');
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  void _playNext() {
    if (_index + 1 < widget.videos.length) {
      _index += 1;
      _loadAtIndex(_index);
    } else {
      // reached end, pop
      Navigator.pop(context);
    }
  }

  void _playPrev() {
    if (_index - 1 >= 0) {
      _index -= 1;
      _loadAtIndex(_index);
    }
  }

  @override
  void dispose() {
    try {
      _chewieController?.dispose();
    } catch (_) {}
    try {
      _vController?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = (widget.videos[_index]['text'] as String?) ?? 'Video';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: _loading
            ? const CircularProgressIndicator()
            : _error
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Failed to load video'),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: _playNext, child: const Text('Skip')),
                    ],
                  )
                : Chewie(controller: _chewieController!),
      ),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(onPressed: _playPrev, icon: const Icon(Icons.skip_previous)),
            Text(' ${_index + 1} / ${widget.videos.length} '),
            IconButton(onPressed: _playNext, icon: const Icon(Icons.skip_next)),
          ],
        ),
      ),
    );
  }
}
