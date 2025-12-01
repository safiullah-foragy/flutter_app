import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'supabase.dart' as sb;

class VideosPage extends StatefulWidget {
  const VideosPage({super.key});

  @override
  State<VideosPage> createState() => _VideosPageState();
}

class _VideosPageState extends State<VideosPage> {
  // List is provided by a StreamBuilder below; no local cache needed

  @override
  Widget build(BuildContext context) {
    // Open the Reels experience by default (<=20s videos with download option)
    return ReelsPage();
  }
}

class ReelsPage extends StatelessWidget {
  ReelsPage({super.key});
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reels')),
      body: StreamBuilder<QuerySnapshot>(
    stream: _firestore
      .collection('posts')
      .where('is_private', isEqualTo: false)
      .snapshots(includeMetadataChanges: true),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = List<QueryDocumentSnapshot>.from(snapshot.data!.docs);
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
          }).where((m) => ((m['video_url'] ?? '') as String).isNotEmpty).toList();

          if (videos.isEmpty) return const Center(child: Text('No videos'));

          // Prefer posts that already store a short duration (<= 20s) if available
          final shortByMeta = videos.where((m) {
            final dur = m['video_duration'];
            if (dur is int) return dur <= 20;
            if (dur is double) return dur <= 20.0;
            if (dur is num) return dur.toDouble() <= 20.0;
            return false;
          }).toList();
          final toPlay = shortByMeta.isNotEmpty ? shortByMeta : videos;

          return ReelsPlayerScreen(videos: toPlay);
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

    final rawUrl = (widget.videos[idx]['video_url'] as String?) ?? '';
    debugPrint('🎬 VideoPlayerScreen: Loading video at index $idx, rawUrl: $rawUrl');
    final url = await _resolveVideoUrl(rawUrl);
    debugPrint('🎬 VideoPlayerScreen: Resolved URL: $url');
    if (url.isEmpty) {
      debugPrint('🎬 VideoPlayerScreen: URL is empty, showing error');
      setState(() {
        _error = true;
        _loading = false;
      });
      return;
    }

    try {
      debugPrint('🎬 VideoPlayerScreen: Creating VideoPlayerController for URL: $url');
      _vController = VideoPlayerController.networkUrl(Uri.parse(url));
      debugPrint('🎬 VideoPlayerScreen: Initializing video controller...');
      await _vController!.initialize().timeout(const Duration(seconds: 12));
      debugPrint('🎬 VideoPlayerScreen: Video initialized successfully');
      final duration = _vController!.value.duration;
      debugPrint('🎬 VideoPlayerScreen: Video duration: ${duration.inSeconds}s');
      debugPrint('🎬 VideoPlayerScreen: Proceeding to play (unlimited duration)');
      debugPrint('🎬 VideoPlayerScreen: Creating ChewieController...');
      _chewieController = ChewieController(
        videoPlayerController: _vController!,
        autoPlay: true,
        looping: false,
        allowMuting: true,
        errorBuilder: (context, errorMessage) {
          debugPrint('🎬 VideoPlayerScreen: Error in player: $errorMessage');
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red),
                const SizedBox(height: 8),
                Text('Video error: $errorMessage'),
              ],
            ),
          );
        },
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

      debugPrint('🎬 VideoPlayerScreen: Video ready to play');
      setState(() {
        _loading = false;
        _error = false;
      });
    } catch (e) {
      debugPrint('🎬 VideoPlayerScreen: Video init error for $url: $e');
      print('Video init error for $url: $e');
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  Future<bool> _validateUrlExists(String url) async {
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      client.userAgent = 'MyApp/1.0';
      final req = await client.openUrl('HEAD', uri);
      final resp = await req.close();
      final status = resp.statusCode;
      final ok = status >= 200 && status < 300;
      client.close(force: true);
      return ok;
    } catch (_) {
      try {
        final uri = Uri.parse(url);
        final client = HttpClient();
        client.userAgent = 'MyApp/1.0';
        final req = await client.getUrl(uri);
        req.headers.add('Range', 'bytes=0-0');
        final resp = await req.close();
        final status = resp.statusCode;
        final ok = (status >= 200 && status < 300) || status == 206;
        client.close(force: true);
        return ok;
      } catch (_) {
        return false;
      }
    }
  }

  Future<String> _resolveVideoUrl(String url) async {
    debugPrint('🎬 _resolveVideoUrl: Input URL: $url');
    if (url.isEmpty) {
      debugPrint('🎬 _resolveVideoUrl: URL is empty, returning empty');
      return '';
    }
    
    // On web, skip validation due to CORS issues - trust Supabase URLs
    if (kIsWeb && url.contains('supabase.co')) {
      debugPrint('🎬 _resolveVideoUrl: Web platform, trusting Supabase URL: $url');
      return url;
    }
    
    debugPrint('🎬 _resolveVideoUrl: Validating URL exists...');
    if (await _validateUrlExists(url)) {
      debugPrint('🎬 _resolveVideoUrl: URL is valid and exists, returning: $url');
      return url;
    }
    debugPrint('🎬 _resolveVideoUrl: URL validation failed, trying to create signed URL...');
    try {
      final marker = '/storage/v1/object/public/';
      final idx = url.indexOf(marker);
      if (idx == -1) {
        debugPrint('🎬 _resolveVideoUrl: Marker not found in URL');
        return '';
      }
      final tail = url.substring(idx + marker.length);
      final parts = tail.split('/');
      if (parts.length < 2) {
        debugPrint('🎬 _resolveVideoUrl: Not enough parts in URL path');
        return '';
      }
      final bucket = parts[0];
      final objectPath = parts.sublist(1).join('/');
      debugPrint('🎬 _resolveVideoUrl: Creating signed URL for bucket: $bucket, path: $objectPath');
      final dynamic signed = await sb.supabase.storage.from(bucket).createSignedUrl(objectPath, 60 * 60);
      final String? signedUrl = signed?.toString();
      if (signedUrl == null) {
        debugPrint('🎬 _resolveVideoUrl: Failed to create signed URL');
        return '';
      }
      debugPrint('🎬 _resolveVideoUrl: Signed URL created: $signedUrl');
      
      // On web, trust signed URLs without validation due to CORS
      if (kIsWeb) {
        debugPrint('🎬 _resolveVideoUrl: Web platform, trusting signed URL');
        return signedUrl;
      }
      
      final isValid = await _validateUrlExists(signedUrl);
      debugPrint('🎬 _resolveVideoUrl: Signed URL validation: $isValid');
      return isValid ? signedUrl : '';
    } catch (e) {
      debugPrint('🎬 _resolveVideoUrl: Exception during URL resolution: $e');
      return '';
    }
  }

  Future<void> _downloadCurrent() async {
    final rawUrl = (widget.videos[_index]['video_url'] as String?) ?? '';
    final url = await _resolveVideoUrl(rawUrl);
    if (url.isEmpty) {
      Fluttertoast.showToast(msg: 'Video URL not available');
      return;
    }
    final uri = Uri.parse(url);
    final ok = await canLaunchUrl(uri);
    if (!ok) {
      Fluttertoast.showToast(msg: 'Could not open downloader');
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ElevatedButton(onPressed: _playNext, child: const Text('Skip')),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: _downloadCurrent, // opens externally via url_launcher
                            child: const Text('Open externally'),
                          ),
                        ],
                      ),
                    ],
                  )
                : Chewie(controller: _chewieController!),
      ),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              onPressed: _downloadCurrent,
              icon: const Icon(Icons.download),
              label: const Text('Download'),
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

class ReelsPlayerScreen extends StatefulWidget {
  final List<Map<String, dynamic>> videos;
  const ReelsPlayerScreen({super.key, required this.videos});

  @override
  State<ReelsPlayerScreen> createState() => _ReelsPlayerScreenState();
}

class _ReelsPlayerScreenState extends State<ReelsPlayerScreen> {
  final PageController _pageController = PageController();
  int _index = 0;
  VideoPlayerController? _vController;
  ChewieController? _chewieController;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _loadAtIndex(0);
    _pageController.addListener(() {
      final newPage = _pageController.page?.round() ?? 0;
      if (newPage != _index) {
        _index = newPage;
        _loadAtIndex(_index);
      }
    });
  }

  Future<void> _loadAtIndex(int idx) async {
    setState(() {
      _loading = true;
      _error = false;
    });
    // dispose previous
  try { _chewieController?.dispose(); } catch (_) {}
  try { _vController?.dispose(); } catch (_) {}
    _chewieController = null;
    _vController = null;

    final rawUrl = (widget.videos[idx]['video_url'] as String?) ?? '';
    final url = await _resolveVideoUrl(rawUrl);
    if (url.isEmpty) {
      setState(() { _error = true; _loading = false; });
      return;
    }
    try {
      _vController = VideoPlayerController.networkUrl(Uri.parse(url));
      await _vController!.initialize().timeout(const Duration(seconds: 12));
      // Play videos of any duration
      _chewieController = ChewieController(
        videoPlayerController: _vController!,
        autoPlay: true,
        looping: true,
        allowMuting: true,
        errorBuilder: (context, errorMessage) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red),
              const SizedBox(height: 8),
              Text('Video error: $errorMessage'),
            ],
          ),
        ),
      );
      setState(() { _loading = false; _error = false; });
    } catch (e) {
      setState(() { _error = true; _loading = false; });
    }
  }

  void _playNext() {
    if (_index + 1 < widget.videos.length) {
      _pageController.animateToPage(
        _index + 1,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<bool> _validateUrlExists(String url) async {
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      client.userAgent = 'MyApp/1.0';
      final req = await client.openUrl('HEAD', uri);
      final resp = await req.close();
      final status = resp.statusCode;
      final ok = status >= 200 && status < 300;
      client.close(force: true);
      return ok;
    } catch (_) {
      try {
        final uri = Uri.parse(url);
        final client = HttpClient();
        client.userAgent = 'MyApp/1.0';
        final req = await client.getUrl(uri);
        req.headers.add('Range', 'bytes=0-0');
        final resp = await req.close();
        final status = resp.statusCode;
        final ok = (status >= 200 && status < 300) || status == 206;
        client.close(force: true);
        return ok;
      } catch (_) { return false; }
    }
  }

  Future<String> _resolveVideoUrl(String url) async {
    if (url.isEmpty) return '';
    if (await _validateUrlExists(url)) return url;
    try {
      final marker = '/storage/v1/object/public/';
      final idx = url.indexOf(marker);
      if (idx == -1) return '';
      final tail = url.substring(idx + marker.length);
      final parts = tail.split('/');
      if (parts.length < 2) return '';
      final bucket = parts[0];
      final objectPath = parts.sublist(1).join('/');
      final dynamic signed = await sb.supabase.storage.from(bucket).createSignedUrl(objectPath, 60 * 60);
      final String? signedUrl = signed?.toString();
      if (signedUrl == null) return '';
      return (await _validateUrlExists(signedUrl)) ? signedUrl : '';
    } catch (_) { return ''; }
  }

  Future<void> _downloadCurrent() async {
    final rawUrl = (widget.videos[_index]['video_url'] as String?) ?? '';
    final url = await _resolveVideoUrl(rawUrl);
    if (url.isEmpty) {
      Fluttertoast.showToast(msg: 'Video URL not available');
      return;
    }
    final uri = Uri.parse(url);
    if (!await canLaunchUrl(uri)) {
      Fluttertoast.showToast(msg: 'Could not open downloader');
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    try { _chewieController?.dispose(); } catch (_) {}
    try { _vController?.dispose(); } catch (_) {}
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: widget.videos.length,
            itemBuilder: (context, index) {
              final text = (widget.videos[index]['text'] as String?) ?? '';
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_error)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Failed to load'),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ElevatedButton(
                                onPressed: _playNext,
                                child: const Text('Skip'),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton(
                                onPressed: _downloadCurrent,
                                child: const Text('Open externally'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else
                    Chewie(controller: _chewieController!),
                  // Simple overlay
                  Positioned(
                    left: 16,
                    bottom: 32,
                    right: 16,
                    child: Text(
                      text,
                      style: const TextStyle(color: Colors.white, fontSize: 16, shadows: [
                        Shadow(blurRadius: 8, color: Colors.black, offset: Offset(1, 1)),
                      ]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              );
            },
          ),
          Positioned(
            right: 16,
            bottom: 32,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton(
                  heroTag: 'download',
                  mini: true,
                  onPressed: _downloadCurrent,
                  child: const Icon(Icons.download),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
