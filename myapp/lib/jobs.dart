import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:video_compress/video_compress.dart';

import 'supabase.dart' as sb;

class JobsPage extends StatefulWidget {
  const JobsPage({super.key});

  @override
  State<JobsPage> createState() => _JobsPageState();
}

class _JobsPageState extends State<JobsPage> with TickerProviderStateMixin {
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();
  final Map<String, TextEditingController> perPostCommentControllers = {};

  File? _pickedImage;
  File? _pickedVideo;
  bool _posting = false;

  // video player controllers on-demand for preview dialog
  final Map<String, VideoPlayerController> _previewVideoControllers = {};
  final Map<String, ChewieController> _previewChewieControllers = {};

  @override
  void dispose() {
    _descriptionController.dispose();
    _commentController.dispose();
    perPostCommentControllers.forEach((_, c) => c.dispose());
    for (var c in _previewChewieControllers.values) {
      c.dispose();
    }
    for (var c in _previewVideoControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1600);
    if (file != null) {
      setState(() {
        _pickedImage = File(file.path);
        _pickedVideo = null;
      });
    }
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickVideo(source: ImageSource.gallery);
    if (file != null) {
      setState(() {
        _pickedVideo = File(file.path);
        _pickedImage = null;
      });
    }
  }

  // Try to transcode/compress to H.264/AAC MP4 for maximum device compatibility
  Future<File> _prepareVideoForUpload(File input) async {
    if (kIsWeb) return input; // not supported on web
    try {
      await VideoCompress.setLogLevel(0);
      final info = await VideoCompress.compressVideo(
        input.path,
        quality: VideoQuality.MediumQuality,
        includeAudio: true,
        deleteOrigin: false,
      );
      if (info != null && info.path != null && info.path!.isNotEmpty) {
        return File(info.path!);
      }
    } catch (_) {
      // fall back to original if compression fails
    }
    return input;
  }

  Future<void> _postJob() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('You must be signed in to post a job')));
      return;
    }

    final description = _descriptionController.text.trim();
    if (description.isEmpty && _pickedImage == null && _pickedVideo == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a description or pick a photo/video')));
      return;
    }

    setState(() => _posting = true);

    try {
      String imageUrl = '';
      String videoUrl = '';
      final ts = DateTime.now().millisecondsSinceEpoch;
      if (_pickedImage != null) {
        final fn = 'job_$ts.jpg';
        imageUrl = await sb.uploadPostImage(_pickedImage!, fileName: fn);
      }
      if (_pickedVideo != null) {
        // Compress/transcode to MP4 (H.264/AAC) when possible
        final prepared = await _prepareVideoForUpload(_pickedVideo!);
        final fn = 'job_$ts.mp4';
        videoUrl = await sb.uploadVideo(prepared, fileName: fn);
      }

      // Create a post in `posts` marked as a job post
      final timestamp = ts;
      final doc = {
        'user_id': user.uid,
        'text': description,
        'image_url': imageUrl,
        'video_url': videoUrl,
        'timestamp': timestamp,
        'is_private': false,
        'likes_count': 0,
        'comments_count': 0,
        'post_type': 'job', // identification for jobs feed
      };

      await FirebaseFirestore.instance.collection('posts').add(doc);

      // clear composer
      _descriptionController.clear();
      setState(() {
        _pickedImage = null;
        _pickedVideo = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Job posted')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to post job: $e')));
    } finally {
      setState(() => _posting = false);
    }
  }

  Future<void> _toggleLike(String postId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final postRef = FirebaseFirestore.instance.collection('posts').doc(postId);
    final likeRef = postRef.collection('likes').doc(user.uid);

    await FirebaseFirestore.instance.runTransaction((tx) async {
      final likeSnap = await tx.get(likeRef);
      if (likeSnap.exists) {
        // Unlike
        tx.delete(likeRef);
        tx.update(postRef, {'likes_count': FieldValue.increment(-1)});
      } else {
        // Like with default reaction 'like'
        tx.set(likeRef, {
          // Per security rules, like docs may only contain 'reaction' and 'timestamp'
          'reaction': 'like',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        tx.update(postRef, {'likes_count': FieldValue.increment(1)});
      }
    });
  }

  Future<void> _addComment(String postId, TextEditingController controller) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;

    final ts = DateTime.now().millisecondsSinceEpoch;
    await FirebaseFirestore.instance
        .collection('posts')
        .doc(postId)
        .collection('comments')
        .add({'user_id': user.uid, 'text': text, 'timestamp': ts});
    await FirebaseFirestore.instance.collection('posts').doc(postId).update({'comments_count': FieldValue.increment(1)});
    controller.clear();
  }

  Future<void> _editComment(String postId, String commentId, String currentText) async {
    final controller = TextEditingController(text: currentText);
    final newText = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Edit Comment'),
        content: TextField(controller: controller, maxLines: null),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || newText == currentText) return;
    try {
      await FirebaseFirestore.instance
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .doc(commentId)
          .update({'text': newText, 'edited': true});
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update comment: $e')));
    }
  }

  Future<void> _deleteComment(String postId, String commentId) async {
    try {
      await FirebaseFirestore.instance
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .doc(commentId)
          .delete();
      await FirebaseFirestore.instance.collection('posts').doc(postId).update({'comments_count': FieldValue.increment(-1)});
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete comment: $e')));
    }
  }

  Future<void> _deletePost(String postId) async {
    try {
      await FirebaseFirestore.instance.collection('posts').doc(postId).delete();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Post deleted')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
    }
  }

  Future<void> _togglePrivacy(String postId, bool current) async {
    try {
      await FirebaseFirestore.instance.collection('posts').doc(postId).update({'is_private': !current});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Post set to ${!current ? 'private' : 'public'}')));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update privacy: $e')));
    }
  }

  Future<void> _editPostText(String postId, String currentText) async {
    final controller = TextEditingController(text: currentText);
    final newText = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Edit Job Post'),
        content: TextField(controller: controller, maxLines: null),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || newText == currentText) return;
    try {
      await FirebaseFirestore.instance.collection('posts').doc(postId).update({'text': newText, 'edited': true});
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
    }
  }

  Widget _composer() {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _descriptionController,
              maxLines: null,
              decoration: const InputDecoration(hintText: 'Describe the job (title, location, details)'),
            ),
            const SizedBox(height: 8),
            if (_pickedImage != null)
              Stack(
                children: [
                  Image.file(_pickedImage!, height: 160, width: double.infinity, fit: BoxFit.cover),
                  Positioned(
                    right: 4,
                    top: 4,
                    child: CircleAvatar(
                      backgroundColor: Colors.black54,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 18),
                        onPressed: () => setState(() => _pickedImage = null),
                      ),
                    ),
                  ),
                ],
              ),
            if (_pickedVideo != null)
              Container(
                height: 160,
                color: Colors.black12,
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.videocam, size: 28),
                      SizedBox(width: 8),
                      Text('Video selected'),
                    ],
                  ),
                ),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  TextButton.icon(onPressed: _pickImage, icon: const Icon(Icons.photo), label: const Text('Photo')),
                  TextButton.icon(onPressed: _pickVideo, icon: const Icon(Icons.videocam), label: const Text('Video')),
                ]),
                ElevatedButton(
                  onPressed: _posting ? null : _postJob,
                  child: _posting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Post Job'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _jobTile(DocumentSnapshot doc, {required bool isOwner}) {
    final data = doc.data() as Map<String, dynamic>;
    final postId = doc.id;
    final postOwnerId = data['user_id']?.toString() ?? '';
    final description = data['text']?.toString() ?? '';
    final imageUrl = data['image_url']?.toString() ?? '';
    final videoUrl = data['video_url']?.toString() ?? '';
    final likesCount = (data['likes_count'] ?? 0) as int;
    final commentsCount = (data['comments_count'] ?? 0) as int;
    final isPrivate = (data['is_private'] ?? false) as bool;
    final uid = FirebaseAuth.instance.currentUser?.uid;

    DateTime dateTime;
    final timestamp = data['timestamp'];
    if (timestamp is int) {
      dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
    } else if (timestamp is Timestamp) {
      dateTime = timestamp.toDate();
    } else {
      dateTime = DateTime.now();
    }

    perPostCommentControllers[postId] ??= TextEditingController();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Posted on: ${dateTime.toLocal().toString().split('.').first}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                if (isOwner)
                  PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') {
                        _editPostText(postId, description);
                      } else if (v == 'delete') {
                        _deletePost(postId);
                      } else if (v == 'privacy') {
                        _togglePrivacy(postId, isPrivate);
                      }
                    },
                    itemBuilder: (c) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete')),
                      PopupMenuItem(value: 'privacy', child: Text(isPrivate ? 'Make Public' : 'Make Private')),
                    ],
                  ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(description, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            ],
            if (imageUrl.isNotEmpty) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  height: 200,
                  width: double.infinity,
                  placeholder: (c, _) => Container(color: Colors.grey[200], height: 200, child: const Center(child: CircularProgressIndicator())),
                  errorWidget: (c, u, e) => Container(color: Colors.grey[200], height: 200, child: const Icon(Icons.error, color: Colors.red)),
                ),
              ),
            ],
            if (videoUrl.isNotEmpty) ...[
              const SizedBox(height: 8),
              _InlineVideoPlayer(url: videoUrl),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                StreamBuilder<DocumentSnapshot>(
                  stream: FirebaseFirestore.instance.collection('posts').doc(postId).collection('likes').doc(uid).snapshots(),
                  builder: (c, snap) {
                    final liked = snap.data?.exists ?? false;
                    return TextButton.icon(
                      onPressed: () => _toggleLike(postId),
                      icon: Icon(liked ? Icons.thumb_up : Icons.thumb_up_outlined),
                      label: Text('$likesCount'),
                    );
                  },
                ),
                const SizedBox(width: 16),
                Icon(Icons.comment_outlined, size: 20),
                const SizedBox(width: 4),
                Text('$commentsCount'),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: perPostCommentControllers[postId],
                    decoration: const InputDecoration(hintText: 'Write a comment'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: () => _addComment(postId, perPostCommentControllers[postId]!),
                ),
              ],
            ),
            const SizedBox(height: 4),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('posts')
                  .doc(postId)
                  .collection('comments')
                  .orderBy('timestamp', descending: false)
                  .limit(5)
                  .snapshots(includeMetadataChanges: true),
              builder: (c, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                final docs = snap.data!.docs;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final cm in docs) ...[
                      Builder(builder: (context) {
                        final cmData = cm.data() as Map<String, dynamic>;
                        final cmId = cm.id;
                        final cmText = (cmData['text'] ?? '').toString();
                        final cmUserId = (cmData['user_id'] ?? '').toString();
                        final me = FirebaseAuth.instance.currentUser?.uid;
                        final canEdit = me != null && cmUserId == me; // author
                        final canDelete = canEdit || (me != null && me == postOwnerId); // author or post owner
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: Text(cmText, style: const TextStyle(fontSize: 13))),
                              if (canEdit)
                                IconButton(
                                  icon: const Icon(Icons.edit, size: 16),
                                  tooltip: 'Edit',
                                  onPressed: () => _editComment(postId, cmId, cmText),
                                ),
                              if (canDelete)
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 16),
                                  tooltip: 'Delete',
                                  onPressed: () => _deleteComment(postId, cmId),
                                ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // Inline player now used instead of dialog-based playback.

  Widget _jobsFeedList() {
    // Public jobs only (is_private == false)
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .where('post_type', isEqualTo: 'job')
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
          final ad = (a.data() as Map<String, dynamic>?)?['timestamp'];
          final bd = (b.data() as Map<String, dynamic>?)?['timestamp'];
          int ai = ad is int ? ad : (ad is Timestamp ? ad.millisecondsSinceEpoch : 0);
          int bi = bd is int ? bd : (bd is Timestamp ? bd.millisecondsSinceEpoch : 0);
          return bi.compareTo(ai);
        });
        if (docs.isEmpty) {
          return const Center(child: Text('No job posts yet'));
        }
        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (c, i) => _jobTile(docs[i], isOwner: false),
        );
      },
    );
  }

  Widget _myJobsList() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Center(child: Text('Sign in to see your posts'));
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('posts')
          .where('post_type', isEqualTo: 'job')
          .where('user_id', isEqualTo: uid)
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
          final ad = (a.data() as Map<String, dynamic>?)?['timestamp'];
          final bd = (b.data() as Map<String, dynamic>?)?['timestamp'];
          int ai = ad is int ? ad : (ad is Timestamp ? ad.millisecondsSinceEpoch : 0);
          int bi = bd is int ? bd : (bd is Timestamp ? bd.millisecondsSinceEpoch : 0);
          return bi.compareTo(ai);
        });
        if (docs.isEmpty) {
          return const Center(child: Text('You have no job posts yet'));
        }
        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (c, i) => _jobTile(docs[i], isOwner: true),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Jobs'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Job Feed'),
              Tab(text: 'My Posts'),
            ],
          ),
        ),
        body: Column(
          children: [
            _composer(),
            const SizedBox(height: 8),
            Expanded(
              child: TabBarView(
                children: [
                  _jobsFeedList(),
                  _myJobsList(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineVideoPlayer extends StatefulWidget {
  final String url;
  const _InlineVideoPlayer({required this.url});

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> {
  VideoPlayerController? _vpc;
  ChewieController? _chewie;
  String? _error;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      await controller.initialize();
      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: false,
        looping: false,
        allowMuting: true,
        showControls: true,
      );
      setState(() {
        _vpc = controller;
        _chewie = chewie;
        _initialized = true;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _vpc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        height: 200,
        color: Colors.black12,
        alignment: Alignment.center,
        child: Text(
          'Unable to play video: $_error',
          style: const TextStyle(color: Colors.red, fontSize: 12),
        ),
      );
    }
    if (!_initialized || _vpc == null || _chewie == null) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final ar = _vpc!.value.aspectRatio == 0 ? (16 / 9) : _vpc!.value.aspectRatio;
    return AspectRatio(
      aspectRatio: ar,
      child: Chewie(controller: _chewie!),
    );
  }
}