import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:permission_handler/permission_handler.dart';
import 'supabase.dart' as sb;
import 'see_profile_from_newsfeed.dart';
import 'videos.dart';
import 'messages.dart';
import 'jobs.dart';

class NewsfeedPage extends StatefulWidget {
  const NewsfeedPage({super.key});

  @override
  State<NewsfeedPage> createState() => _NewsfeedPageState();
}

class _NewsfeedPageState extends State<NewsfeedPage> with TickerProviderStateMixin {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _postController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();
  // per-post comment controllers to avoid sharing a single controller across posts
  Map<String, TextEditingController> perPostCommentControllers = {};
  final Connectivity _connectivity = Connectivity();
  final ScrollController _scrollController = ScrollController();

  File? _selectedImage;
  File? _selectedVideo;
  Map<String, dynamic>? userData;
  List<Map<String, dynamic>> posts = [];
  Map<String, List<Map<String, dynamic>>> postComments = {};
  Map<String, int> postLikes = {};
  Map<String, int> postCommentCounts = {};
  Map<String, String> userReactions = {};
  Map<String, bool> commentEditing = {};
  Map<String, TextEditingController> commentEditControllers = {};
  Map<String, bool> expandedComments = {};
  Map<String, Map<String, dynamic>?> userCache = {};
  // video player controllers are initialized lazily to avoid blocking initial load
  Map<String, VideoPlayerController?> videoPlayerControllers = {};
  Map<String, ChewieController?> videoControllers = {};
  Map<String, AnimationController?> likeAnimationControllers = {};
  // Cache of resolved image URLs (may be signed) keyed by postId
  Map<String, String> resolvedImageUrls = {};
  StreamSubscription<QuerySnapshot>? _postsSubscription;
  StreamSubscription<DocumentSnapshot>? _currentUserSubscription;
  Map<String, StreamSubscription<QuerySnapshot>?> commentSubscriptions = {};
  // Live like state per post for the current user
  Map<String, StreamSubscription<DocumentSnapshot>?> likeSubscriptions = {};
  // Live author profile updates per user id
  Map<String, StreamSubscription<DocumentSnapshot>?> authorSubscriptions = {};
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;
  bool isLoading = true;
  bool hasConnection = true;
  bool _showComposer = true;

  @override
  void initState() {
    super.initState();
    _firestore.settings = const Settings(persistenceEnabled: true);
    _checkConnectivity();
    _fetchUserData();
    _fetchInitialPosts();
    _setupPostsListener();
  }

  void _checkConnectivity() {
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen((ConnectivityResult result) {
      setState(() {
        hasConnection = result != ConnectivityResult.none;
      });
      if (!hasConnection) {
        Fluttertoast.showToast(msg: 'No internet connection. Showing cached data if available.');
      }
    });
  }

  @override
  void dispose() {
    _postController.dispose();
    _commentController.dispose();
    perPostCommentControllers.forEach((_, c) => c.dispose());
    commentEditControllers.forEach((_, controller) => controller.dispose());
    videoControllers.forEach((_, controller) => controller?.dispose());
    videoPlayerControllers.forEach((_, controller) => controller?.dispose());
    likeAnimationControllers.forEach((_, controller) => controller?.dispose());
    _postsSubscription?.cancel();
    commentSubscriptions.forEach((_, sub) => sub?.cancel());
    likeSubscriptions.forEach((_, sub) => sub?.cancel());
    authorSubscriptions.forEach((_, sub) => sub?.cancel());
    _currentUserSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions(Permission permission) async {
    try {
      final status = await permission.request();
      if (status.isDenied) {
        Fluttertoast.showToast(
          msg: 'Permission denied. Please enable ${permission.toString().split('.').last} access in settings.',
          toastLength: Toast.LENGTH_LONG,
        );
        await openAppSettings();
      } else if (status.isPermanentlyDenied) {
        Fluttertoast.showToast(
          msg: 'Permission permanently denied. Please enable in settings.',
          toastLength: Toast.LENGTH_LONG,
        );
        await openAppSettings();
      }
    } catch (e) {
      print('Error requesting permission: $e');
      // Avoid showing random error messages
    }
  }

  Future<void> _fetchUserData() async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        return;
      }
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (userDoc.exists) {
        setState(() {
          userData = userDoc.data() as Map<String, dynamic>?;
          userCache[user.uid] = userData;
        });
        _setupCurrentUserListener(user.uid);
      }
    } catch (e) {
      print('Error fetching user data: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently or log
      } else {
        // Avoid showing toast
      }
    }
  }

  void _setupCurrentUserListener(String uid) {
    _currentUserSubscription?.cancel();
    _currentUserSubscription = _firestore.collection('users').doc(uid).snapshots().listen((doc) {
      if (!doc.exists) return;
      final Map<String, dynamic>? data = doc.data();
      if (data == null) return;
      setState(() {
        userData = data;
        userCache[uid] = data;
      });
    }, onError: (e) {
      // silent
    });
  }

  void _attachAuthorListener(String userId) {
    if (userId.isEmpty) return;
    if (authorSubscriptions.containsKey(userId)) return;
    authorSubscriptions[userId] = _firestore.collection('users').doc(userId).snapshots().listen((doc) {
      if (!doc.exists) return;
      final Map<String, dynamic>? data = doc.data();
      if (data == null) return;
      userCache[userId] = data;
      if (mounted) setState(() {});
    }, onError: (_) {});
  }

  void _attachLikeListener(String postId) {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    // Dispose any previous listener for this postId
    likeSubscriptions[postId]?.cancel();
    likeSubscriptions[postId] = _firestore
        .collection('posts')
        .doc(postId)
        .collection('likes')
        .doc(uid)
        .snapshots()
        .listen((doc) {
      if (!doc.exists) {
        userReactions[postId] = '';
      } else {
        try {
          userReactions[postId] = (doc.get('reaction') ?? 'like') as String;
        } catch (_) {
          userReactions[postId] = 'like';
        }
      }
      if (mounted) setState(() {});
    }, onError: (_) {});
  }

  Future<void> _fetchInitialPosts() async {
    try {
      Query query = _firestore
          .collection('posts')
          .where('is_private', isEqualTo: false)
          .orderBy('timestamp', descending: true);

      QuerySnapshot postsSnapshot;
      try {
        // Try cache first so UI shows instantly even offline
        postsSnapshot = await query.get(const GetOptions(source: Source.cache));
        // If cache is empty and we have connectivity, fall back to server
        if ((postsSnapshot.docs.isEmpty) && hasConnection) {
          postsSnapshot = await query.get();
        }
      } catch (_) {
        // If orderBy requires index or cache miss, try unordered, sorted client-side
        try {
          final unordered = await _firestore
              .collection('posts')
              .where('is_private', isEqualTo: false)
              .get(const GetOptions(source: Source.cache));
          postsSnapshot = unordered;
        } catch (e) {
          // Final fallback to server unordered
          postsSnapshot = await _firestore
              .collection('posts')
              .where('is_private', isEqualTo: false)
              .get();
        }
      }

      List<Map<String, dynamic>> postsList = [];
      for (var doc in postsSnapshot.docs) {
        try {
          final postData = doc.data() as Map<String, dynamic>?;
          if (postData == null) continue;
          String postId = doc.id;

          String userId = postData['user_id'] ?? '';
          Map<String, dynamic>? postUserData = userCache[userId];
          // Attach listener (will populate cache and refresh UI when it arrives)
          _attachAuthorListener(userId);

          // Seed current reaction; live updates are handled by _attachLikeListener
          // Seed current reaction lazily via listener to avoid extra round-trips
          userReactions[postId] = userReactions[postId] ?? '';
          _attachLikeListener(postId);

          postsList.add({
            'id': postId,
            ...postData,
            'user_data': postUserData,
          });

          postLikes[postId] = postData['likes_count'] ?? 0;
          postCommentCounts[postId] = postData['comments_count'] ?? 0;

          // Defer video initialization until the post is visible to improve load performance.
          if ((postData['video_url'] as String?)?.isNotEmpty ?? false) {
            videoPlayerControllers[postId] = null;
            videoControllers[postId] = null;
          }
          // Attempt to resolve an accessible image URL (signed fallback) asynchronously
          final imgUrl = (postData['image_url'] ?? '') as String;
          if (imgUrl.isNotEmpty) {
            _resolveImageUrl(imgUrl).then((resolved) {
              if (resolved != null && mounted) {
                setState(() {
                  resolvedImageUrls[postId] = resolved;
                });
              }
            });
          }
        } catch (postError) {
          print('Error processing post ${doc.id}: $postError');
        }
      }

      // Ensure newest first in case unordered fallback was used
      postsList.sort((a, b) => ((b['timestamp'] ?? 0) as int).compareTo((a['timestamp'] ?? 0) as int));
      setState(() {
        posts = postsList;
        isLoading = false;
      });
      // Clean up like listeners for posts no longer present
      final currentIds = postsList.map((p) => p['id'] as String).toSet();
      final toRemove = likeSubscriptions.keys.where((k) => !currentIds.contains(k)).toList();
      for (final k in toRemove) {
        likeSubscriptions[k]?.cancel();
        likeSubscriptions.remove(k);
      }
    } catch (e) {
      print('Error fetching initial posts: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
      setState(() {
        isLoading = false;
      });
    }
  }

  void _setupPostsListener() {
    _postsSubscription?.cancel();
    final baseQuery = _firestore
        .collection('posts')
        .where('is_private', isEqualTo: false)
        .orderBy('timestamp', descending: true);

    // Use includeMetadataChanges so cache-only updates still trigger rebuilds
    _postsSubscription = baseQuery.snapshots(includeMetadataChanges: true).listen((snapshot) async {
      // Do not block on connectivity; let cache drive UI when offline
      List<Map<String, dynamic>> postsList = [];
      for (var doc in snapshot.docs) {
        try {
          final postData = doc.data() as Map<String, dynamic>?;
          if (postData == null) continue;
          String postId = doc.id;

          String userId = postData['user_id'] ?? '';
          Map<String, dynamic>? postUserData = userCache[userId];
          _attachAuthorListener(userId);

          // Defer reaction resolution to dedicated like listener (fewer round-trips)
          final String userReaction = userReactions[postId] ?? '';
          _attachLikeListener(postId);

          postsList.add({
            'id': postId,
            ...postData,
            'user_data': postUserData,
          });

          postLikes[postId] = postData['likes_count'] ?? 0;
          postCommentCounts[postId] = postData['comments_count'] ?? 0;
          userReactions[postId] = userReaction;
          // videos are handled lazily when user opens a video player screen
          // Resolve image URL (signed fallback) asynchronously
          final imgUrl = (postData['image_url'] ?? '') as String;
          if (imgUrl.isNotEmpty) {
            _resolveImageUrl(imgUrl).then((resolved) {
              if (resolved != null && mounted) {
                setState(() {
                  resolvedImageUrls[postId] = resolved;
                });
              }
            });
          }
        } catch (postError) {
          print('Error processing post ${doc.id}: $postError');
        }
      }

      // Ensure newest first even if server ordering is unavailable
      postsList.sort((a, b) => ((b['timestamp'] ?? 0) as int).compareTo((a['timestamp'] ?? 0) as int));
      setState(() {
        posts = postsList;
        isLoading = false;
      });
    }, onError: (e) {
      print('Error in posts listener: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    });
  }

  Future<void> _fetchComments(String postId) async {
    try {
      QuerySnapshot commentsSnapshot = await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .orderBy('timestamp', descending: false)
          .get();

      List<Map<String, dynamic>> comments = [];
      for (var commentDoc in commentsSnapshot.docs) {
        Map<String, dynamic> commentData = commentDoc.data() as Map<String, dynamic>;
        String commentUserId = commentData['user_id'] ?? '';
        Map<String, dynamic>? commentUserData;

        if (userCache.containsKey(commentUserId)) {
          commentUserData = userCache[commentUserId];
        } else {
          DocumentSnapshot commentUserDoc = await _firestore.collection('users').doc(commentUserId).get();
          if (commentUserDoc.exists) {
            commentUserData = commentUserDoc.data() as Map<String, dynamic>;
            userCache[commentUserId] = commentUserData;
          } else {
            commentUserData = {'name': 'Unknown User', 'profile_image': null};
          }
        }

        comments.add({
          'id': commentDoc.id,
          ...commentData,
          'user_data': commentUserData,
        });
      }

      setState(() {
        postComments[postId] = comments;
      });
    } catch (e) {
      print('Error fetching comments: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
      setState(() {
        postComments[postId] = [];
      });
    }
  }

  Future<void> _createPost() async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        return;
      }
      if (_postController.text.isEmpty && _selectedImage == null && _selectedVideo == null) {
        return;
      }

      String imageUrl = '';
      String videoUrl = '';

      if (_selectedImage != null) {
        final status = await Permission.photos.status;
        if (!status.isGranted) {
          await _requestPermissions(Permission.photos);
          if (!await Permission.photos.isGranted) return;
        }
        final String fileName = 'post_${user.uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
        imageUrl = await sb.uploadPostImage(_selectedImage!, fileName: fileName);
      }

      if (_selectedVideo != null) {
        final String fileName = 'video_${user.uid}_${DateTime.now().millisecondsSinceEpoch}.mp4';
        videoUrl = await sb.uploadVideo(_selectedVideo!, fileName: fileName);
      }

      final int timestamp = DateTime.now().millisecondsSinceEpoch;
      DocumentReference ref = await _firestore.collection('posts').add({
        'user_id': user.uid,
        'text': _postController.text,
        'image_url': imageUrl,
        'video_url': videoUrl,
        'timestamp': timestamp,
        'is_private': false,
        'likes_count': 0,
        'comments_count': 0,
      });

      String postId = ref.id;
      setState(() {
        posts.insert(0, {
          'id': postId,
          'user_id': user.uid,
          'text': _postController.text,
          'image_url': imageUrl,
          'video_url': videoUrl,
          'timestamp': timestamp,
          'is_private': false,
          'likes_count': 0,
          'comments_count': 0,
          'user_data': userData,
        });
        postLikes[postId] = 0;
        postCommentCounts[postId] = 0;
        userReactions[postId] = '';
        _postController.clear();
        _selectedImage = null;
        _selectedVideo = null;
      });
    } catch (e) {
      print('Error creating post: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        Fluttertoast.showToast(msg: 'Failed to create post: $e');
      }
    }
  }

  Future<void> _editPost(String postId, String currentText) async {
    try {
      final controller = TextEditingController(text: currentText);
      final newText = await showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Edit post'),
            content: TextField(
              controller: controller,
              maxLines: null,
              decoration: const InputDecoration(hintText: 'Update your post text'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: const Text('Save'),
              ),
            ],
          );
        },
      );

      if (newText == null) return;
      if (newText == currentText || newText.isEmpty) return;

      await _firestore.collection('posts').doc(postId).update({
        'text': newText,
        'edited': true,
      });

      // Optimistic local update
      final idx = posts.indexWhere((p) => p['id'] == postId);
      if (idx != -1) {
        setState(() {
          posts[idx]['text'] = newText;
          posts[idx]['edited'] = true;
        });
      }
    } catch (e) {
      print('Error editing post: $e');
      // silent on permission errors
    }
  }

  Future<void> _deletePost(String postId) async {
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete post?'),
          content: const Text('This action cannot be undone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
          ],
        ),
      );
      if (confirm != true) return;

      await _firestore.collection('posts').doc(postId).delete();

      // Clean up listeners/controllers and remove from local list
      likeSubscriptions[postId]?.cancel();
      likeSubscriptions.remove(postId);
      commentSubscriptions[postId]?.cancel();
      commentSubscriptions.remove(postId);
      try {
        await videoControllers[postId]?.pause();
      } catch (_) {}
      try {
        videoControllers[postId]?.dispose();
      } catch (_) {}
      videoControllers.remove(postId);
      try {
        await videoPlayerControllers[postId]?.dispose();
      } catch (_) {}
      videoPlayerControllers.remove(postId);

      setState(() {
        posts.removeWhere((p) => p['id'] == postId);
        postLikes.remove(postId);
        postCommentCounts.remove(postId);
        userReactions.remove(postId);
        resolvedImageUrls.remove(postId);
      });
    } catch (e) {
      print('Error deleting post: $e');
    }
  }

  Future<void> _togglePostPrivacy(String postId, bool isPrivateNow) async {
    try {
      final newVal = !isPrivateNow;
      await _firestore.collection('posts').doc(postId).update({'is_private': newVal});

      // If becomes private, it should disappear from public newsfeed immediately
      if (newVal) {
        setState(() {
          posts.removeWhere((p) => p['id'] == postId);
        });
      } else {
        // If becomes public, keep local state; the listener will add it if it matches the query
      }
    } catch (e) {
      print('Error toggling privacy: $e');
    }
  }

  Future<void> _pickImage() async {
    try {
      final status = await Permission.photos.status;
      if (!status.isGranted) {
        await _requestPermissions(Permission.photos);
        if (!await Permission.photos.isGranted) return;
      }

      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (pickedFile != null) {
        setState(() {
          _selectedImage = File(pickedFile.path);
          _selectedVideo = null;
        });
      }
    } catch (e) {
      print('Error picking image: $e');
      // Avoid toast
    }
  }

  Future<void> _pickVideo() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickVideo(
        source: ImageSource.gallery,
      );
      if (pickedFile != null) {
        setState(() {
          _selectedVideo = File(pickedFile.path);
          _selectedImage = null;
        });
      }
    } catch (e) {
      print('Error picking video: $e');
      // Avoid toast
    }
  }

  Future<void> _addComment(String postId, TextEditingController controller) async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        return;
      }
      if (controller.text.isEmpty) {
        return;
      }

      final int timestamp = DateTime.now().millisecondsSinceEpoch;
      DocumentReference ref = await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .add({
        'user_id': user.uid,
        'text': controller.text,
        'timestamp': timestamp,
      });

      await _firestore.collection('posts').doc(postId).update({
        'comments_count': FieldValue.increment(1),
      });

      setState(() {
        postComments[postId] = postComments[postId] ?? [];
        postComments[postId]!.add({
          'id': ref.id,
          'user_id': user.uid,
          'text': controller.text,
          'timestamp': timestamp,
          'user_data': userData,
        });
        postCommentCounts[postId] = (postCommentCounts[postId] ?? 0) + 1;
        controller.clear();
      });
    } catch (e) {
      print('Error adding comment: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  Future<void> _editComment(String postId, String commentId, String newText) async {
    try {
      if (newText.isEmpty) {
        return;
      }
      await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .doc(commentId)
          .update({
        'text': newText,
        'edited': true,
      });

      setState(() {
        commentEditing[commentId] = false;
        if (postComments.containsKey(postId)) {
          final comment = postComments[postId]!.firstWhere((c) => c['id'] == commentId);
          comment['text'] = newText;
          comment['edited'] = true;
        }
      });
    } catch (e) {
      print('Error updating comment: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  Future<void> _deleteComment(String postId, String commentId) async {
    try {
      await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .doc(commentId)
          .delete();

      await _firestore.collection('posts').doc(postId).update({
        'comments_count': FieldValue.increment(-1),
      });

      setState(() {
        if (postComments.containsKey(postId)) {
          postComments[postId]!.removeWhere((c) => c['id'] == commentId);
          postCommentCounts[postId] = (postCommentCounts[postId] ?? 1) - 1;
        }
      });
    } catch (e) {
      print('Error deleting comment: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  Future<void> _toggleLike(String postId, String reaction) async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) return;

      final docRef = _firestore
          .collection('posts')
          .doc(postId)
          .collection('likes')
          .doc(user.uid);

      final likeDoc = await docRef.get();
      final bool wasLiked = likeDoc.exists;
      final String oldReaction = wasLiked ? (likeDoc.get('reaction') ?? 'like') : '';

      if (wasLiked && oldReaction == reaction) {
        // Unlike
        await docRef.delete();
        setState(() {
          userReactions[postId] = '';
          postLikes[postId] = (postLikes[postId] ?? 1) - 1;
        });
        await _firestore.collection('posts').doc(postId).update({
          'likes_count': FieldValue.increment(-1),
        });
      } else {
        // Like or change reaction
        await docRef.set({
          'user_id': user.uid,
          'reaction': reaction,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        setState(() {
          userReactions[postId] = reaction;
          if (!wasLiked) {
            postLikes[postId] = (postLikes[postId] ?? 0) + 1;
          }
          likeAnimationControllers[postId]?.forward(from: 0);
        });
        if (!wasLiked) {
          await _firestore.collection('posts').doc(postId).update({
            'likes_count': FieldValue.increment(1),
          });
        }
      }
    } catch (e) {
      print('Error toggling like: $e');
      if (e is FirebaseException && e.code == 'permission-denied') {
        // Handle silently
      } else {
        // Avoid toast
      }
    }
  }

  Future<void> _initVideoControllers(String postId, String url) async {
    if (url.isEmpty) return;
    try {
      // If a controller already exists, don't re-create
      if (videoPlayerControllers[postId] != null || videoControllers[postId] != null) return;
      // Resolve an accessible URL (public or signed) before initializing.
      final resolvedUrl = await _resolveVideoUrl(url);
      if (resolvedUrl == null) {
        print('Video URL not accessible or returned non-200: $url');
        videoPlayerControllers[postId] = null;
        videoControllers[postId] = null;
        if (mounted) setState(() {});
        return;
      }

      final vpc = VideoPlayerController.networkUrl(Uri.parse(resolvedUrl));
      videoPlayerControllers[postId] = vpc;
      // start initialize and wait
      await vpc.initialize();

      final chewie = ChewieController(
        videoPlayerController: vpc,
        autoInitialize: true,
        autoPlay: false,
        looping: false,
        allowMuting: true,
      );

      videoControllers[postId] = chewie;
      if (mounted) setState(() {});
    } catch (e) {
      print('Error initializing video for $postId: $e');
      // Clean up any partially created controllers
      try {
        await videoPlayerControllers[postId]?.dispose();
      } catch (_) {}
      videoPlayerControllers[postId] = null;
      videoControllers[postId] = null;
      if (mounted) setState(() {});
    }
  }

  /// Check if URL responds with 200 on a HEAD request. Returns false on error
  /// or non-200 responses. This helps avoid initializing ExoPlayer on bad URLs.
  Future<bool> _validateUrlExists(String url) async {
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      client.userAgent = 'MyApp/1.0';
      final req = await client.openUrl('HEAD', uri);
      final resp = await req.close();
      final status = resp.statusCode;
      final ok = status >= 200 && status < 300;
      print('HEAD $url -> $status');
      client.close(force: true);
      return ok;
    } catch (e) {
      // Fallback to GET with Range if HEAD is blocked
      try {
        final uri = Uri.parse(url);
        final client = HttpClient();
        client.userAgent = 'MyApp/1.0';
        final req = await client.getUrl(uri);
        req.headers.add('Range', 'bytes=0-0');
        final resp = await req.close();
        final status = resp.statusCode;
        final ok = (status >= 200 && status < 300) || status == 206;
        print('GET(range) $url -> $status');
        client.close(force: true);
        return ok;
      } catch (e2) {
        print('URL validation error for $url: $e2');
        return false;
      }
    }
  }

  /// If the provided URL is a Supabase storage public URL that returns non-200,
  /// attempt to create a signed URL and return an accessible URL or null.
  Future<String?> _resolveVideoUrl(String url) async {
    // First check the provided URL directly
    final ok = await _validateUrlExists(url);
    if (ok) return url;

    try {
      // Look for the Supabase public storage URL pattern
      final marker = '/storage/v1/object/public/';
      final idx = url.indexOf(marker);
      if (idx == -1) return null;

      final tail = url.substring(idx + marker.length); // bucket/path/to/object
      final parts = tail.split('/');
      if (parts.length < 2) return null;
      final bucket = parts[0];
      final objectPath = parts.sublist(1).join('/');

      // Try to create a signed URL (1 hour). createSignedUrl typically
      // returns a String URL in the supabase client.
      final dynamic signed = await sb.supabase.storage.from(bucket).createSignedUrl(objectPath, 60 * 60);
      final String? signedUrl = signed?.toString();
      print('createSignedUrl result for $objectPath -> $signedUrl');
      if (signedUrl == null) return null;
      final ok2 = await _validateUrlExists(signedUrl);
      print('HEAD on signed URL -> $ok2');
      if (ok2) return signedUrl;
      return null;
    } catch (e) {
      print('Error resolving supabase signed url for $url: $e');
      return null;
    }
  }

  Future<String?> _resolveImageUrl(String url) async {
    final ok = await _validateUrlExists(url);
    if (ok) return url;
    try {
      final marker = '/storage/v1/object/public/';
      final idx = url.indexOf(marker);
      if (idx == -1) return null;
      final tail = url.substring(idx + marker.length);
      final parts = tail.split('/');
      if (parts.length < 2) return null;
      final bucket = parts[0];
      final objectPath = parts.sublist(1).join('/');
      final dynamic signed = await sb.supabase.storage.from(bucket).createSignedUrl(objectPath, 60 * 60);
      final String? signedUrl = signed?.toString();
      if (signedUrl == null) return null;
      if (await _validateUrlExists(signedUrl)) return signedUrl;
      return null;
    } catch (_) {
      return null;
    }
  }

  Widget _buildReactionButton(String emoji, String reaction, String postId) {
    return GestureDetector(
      onTap: () {
        Navigator.pop(context);
        _toggleLike(postId, reaction);
      },
      child: Text(
        emoji,
        style: const TextStyle(fontSize: 30),
      ),
    );
  }

  String _getReactionEmoji(String reaction) {
    switch (reaction) {
      case 'love':
        return '❤️';
      case 'like':
        return '😊';
      case 'sad':
        return '😢';
      case 'angry':
        return '😠';
      default:
        return '👍';
    }
  }

  void _showReactionOptions(String postId) {
    showModalBottomSheet(
      context: context,
      builder: (c) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildReactionButton('❤️', 'love', postId),
                _buildReactionButton('😊', 'like', postId),
                _buildReactionButton('😢', 'sad', postId),
                _buildReactionButton('😠', 'angry', postId),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          toolbarHeight: 48,
          actions: [
            IconButton(
              tooltip: 'Toggle composer',
              icon: Icon(_showComposer ? Icons.expand_less : Icons.expand_more),
              onPressed: () => setState(() => _showComposer = !_showComposer),
            ),
            IconButton(
              tooltip: 'Messages',
              icon: const Icon(Icons.message),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MessagesPage())),
            ),
            IconButton(
              tooltip: 'Videos',
              icon: const Icon(Icons.videocam),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VideosPage())),
            ),
            IconButton(
              tooltip: 'Jobs',
              icon: const Icon(Icons.work),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const JobsPage())),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_showComposer)
              Card(
                margin: const EdgeInsets.all(8.0),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () {
                          if (userData != null && _auth.currentUser != null) {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => SeeProfileFromNewsfeed(userId: _auth.currentUser!.uid),
                              ),
                            );
                          }
                        },
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 20,
                              backgroundColor: Colors.grey[300],
                              backgroundImage: userData?['profile_image'] != null
                                  ? CachedNetworkImageProvider(userData!['profile_image'])
                                  : null,
                              child: userData?['profile_image'] == null
                                  ? const Icon(Icons.person, size: 20, color: Colors.grey)
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              userData?['name'] ?? 'User',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _postController,
                        maxLines: null,
                        minLines: 1,
                        decoration: InputDecoration(
                          hintText: "What's on your mind?",
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.photo_library, size: 24),
                            onPressed: _pickImage,
                            tooltip: 'Add Photo',
                          ),
                          IconButton(
                            icon: const Icon(Icons.video_library, size: 24),
                            onPressed: _pickVideo,
                            tooltip: 'Add Video',
                          ),
                          IconButton(
                            icon: const Icon(Icons.send, size: 24),
                            onPressed: _createPost,
                            tooltip: 'Post',
                          ),
                        ],
                      ),
                      if (_selectedImage != null || _selectedVideo != null)
                        Container(
                          height: 150,
                          margin: const EdgeInsets.only(top: 10),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              if (_selectedImage != null)
                                Expanded(
                                  child: Image.file(
                                    _selectedImage!,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              if (_selectedVideo != null)
                                Expanded(
                                  child: Chewie(
                                    controller: ChewieController(
                                      videoPlayerController: VideoPlayerController.file(_selectedVideo!),
                                      autoInitialize: true,
                                      autoPlay: false,
                                      looping: false,
                                      allowMuting: true,
                                      errorBuilder: (context, errorMessage) => Center(child: Text('Video error: $errorMessage')),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            
            if (!hasConnection)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Text('No internet connection. Showing cached data.'),
              ),
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : posts.isEmpty
                      ? const Center(child: Text('No posts available'))
                      : ListView.builder(
                          controller: _scrollController,
                          itemCount: posts.length,
                          itemBuilder: (context, index) {
                            final post = posts[index];
                            return _buildPostItem(post);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPostItem(Map<String, dynamic> post) {
    final String postId = post['id'];
    final int likesCount = postLikes[postId] ?? 0;
    final int commentsCount = postCommentCounts[postId] ?? 0;
    final String userReaction = userReactions[postId] ?? '';
    final String? currentUid = _auth.currentUser?.uid;
    final bool isOwner = currentUid != null && post['user_id'] == currentUid;
    final bool isPrivate = (post['is_private'] ?? false) as bool;

    if (!likeAnimationControllers.containsKey(postId)) {
      likeAnimationControllers[postId] = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      );
    }

    return Card(
      margin: const EdgeInsets.all(8.0),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SeeProfileFromNewsfeed(userId: post['user_id']),
                      ),
                    );
                  },
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: Colors.grey[300],
                        backgroundImage: post['user_data']?['profile_image'] != null
                            ? CachedNetworkImageProvider(post['user_data']['profile_image'])
                            : null,
                        child: post['user_data']?['profile_image'] == null
                            ? const Icon(Icons.person, size: 20, color: Colors.grey)
                            : null,
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            post['user_data']?['name'] ?? 'Unknown User',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Row(
                            children: [
                              Text(
                                DateFormat('MMM dd, yyyy - HH:mm').format(
                                  DateTime.fromMillisecondsSinceEpoch(post['timestamp'] ?? 0),
                                ),
                                style: const TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                              if (isOwner) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  isPrivate ? Icons.lock : Icons.public,
                                  size: 14,
                                  color: Colors.grey,
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                if (isOwner)
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'edit') {
                        _editPost(postId, (post['text'] ?? '') as String);
                      } else if (value == 'privacy') {
                        _togglePostPrivacy(postId, isPrivate);
                      } else if (value == 'delete') {
                        _deletePost(postId);
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem<String>(
                        value: 'edit',
                        child: Text('Edit post'),
                      ),
                      PopupMenuItem<String>(
                        value: 'privacy',
                        child: Text(isPrivate ? 'Make public' : 'Make private'),
                      ),
                      const PopupMenuItem<String>(
                        value: 'delete',
                        child: Text('Delete post'),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (post['text']?.isNotEmpty ?? false) Text(post['text']),
            const SizedBox(height: 10),
            if (post['image_url']?.isNotEmpty ?? false)
              CachedNetworkImage(
                imageUrl: resolvedImageUrls[postId] ?? post['image_url'],
                placeholder: (context, url) => const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (context, url, error) => const Icon(Icons.error),
                fit: BoxFit.cover,
              ),
            if (post['video_url']?.isNotEmpty ?? false)
              SizedBox(
                height: 200,
                child: Builder(builder: (context) {
                  final url = post['video_url'] as String? ?? '';
                  // kick off lazy initialization if not yet created
                  if ((videoControllers[postId] == null) && (videoPlayerControllers[postId] == null)) {
                    // initialize in background; don't await here
                    _initVideoControllers(postId, url);
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (videoControllers[postId] != null) {
                    return Chewie(controller: videoControllers[postId]!);
                  }

                  // If player exists but chewie not ready, show loading
                  if (videoPlayerControllers[postId] != null && !(videoPlayerControllers[postId]!.value.isInitialized)) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  return const Center(child: Text('Video unavailable'));
                }),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (likesCount > 0)
                  Row(
                    children: [
                      if (userReaction.isNotEmpty) Text(_getReactionEmoji(userReaction)),
                      Text('$likesCount'),
                      const SizedBox(width: 16),
                    ],
                  ),
                if (commentsCount > 0) Text('$commentsCount comments'),
              ],
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                GestureDetector(
                  onTap: () => _toggleLike(postId, 'like'),
                  onLongPress: () => _showReactionOptions(postId),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 1.0, end: 1.2).animate(
                      CurvedAnimation(
                        parent: likeAnimationControllers[postId]!,
                        curve: Curves.easeInOut,
                      ),
                    ),
                    child: Row(
                      children: [
                        if (userReaction.isEmpty)
                          Icon(
                            Icons.thumb_up,
                            color: Colors.grey,
                          )
                        else
                          Text(
                            _getReactionEmoji(userReaction),
                            style: const TextStyle(fontSize: 24, color: Colors.blue),
                          ),
                        const SizedBox(width: 5),
                        Text(
                          userReaction.isEmpty ? 'Like' : 'Liked',
                          style: TextStyle(
                            color: userReaction.isNotEmpty ? Colors.blue : Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      expandedComments[postId] = !(expandedComments[postId] ?? false);
                    });
                    if (expandedComments[postId] ?? false) {
                      _fetchComments(postId);
                      commentSubscriptions[postId]?.cancel();
                      commentSubscriptions[postId] = _firestore
                          .collection('posts')
                          .doc(postId)
                          .collection('comments')
                          .orderBy('timestamp', descending: false)
                          .snapshots()
                          .listen((_) => _fetchComments(postId), onError: (e) {
                        print('Error in comments listener: $e');
                        setState(() {
                          postComments[postId] = [];
                        });
                      });
                    } else {
                      commentSubscriptions[postId]?.cancel();
                      commentSubscriptions.remove(postId);
                      postComments.remove(postId);
                    }
                  },
                  child: Row(
                    children: [
                      const Icon(Icons.comment, color: Colors.grey),
                      const SizedBox(width: 5),
                      const Text('Comment', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                ),
              ],
            ),
            if (expandedComments[postId] ?? false) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: perPostCommentControllers.putIfAbsent(postId, () => TextEditingController()),
                        decoration: const InputDecoration(
                          hintText: 'Write a comment...',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 10),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () => _addComment(postId, perPostCommentControllers[postId]!),
                    ),
                  ],
                ),
              ),
              if (postComments[postId] == null)
                const Center(child: CircularProgressIndicator())
              else if (postComments[postId]!.isEmpty)
                const Text('No comments yet')
              else
                Column(
                  children: postComments[postId]!
                      .map((comment) => _buildCommentItem(postId, comment))
                      .toList(),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCommentItem(String postId, Map<String, dynamic> comment) {
    final String commentId = comment['id'];
    final bool isEditing = commentEditing[commentId] ?? false;

    if (!commentEditControllers.containsKey(commentId)) {
      commentEditControllers[commentId] = TextEditingController(text: comment['text']);
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5.0),
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: Colors.grey[300],
                backgroundImage: comment['user_data']?['profile_image'] != null
                    ? CachedNetworkImageProvider(comment['user_data']['profile_image'])
                    : null,
                child: comment['user_data']?['profile_image'] == null
                    ? const Icon(Icons.person, size: 15, color: Colors.grey)
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  comment['user_data']?['name'] ?? 'Unknown User',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
              if (comment['user_id'] == _auth.currentUser?.uid) ...[
                IconButton(
                  icon: const Icon(Icons.edit, size: 16),
                  onPressed: () {
                    setState(() {
                      commentEditing[commentId] = true;
                    });
                  },
                  tooltip: 'Edit Comment',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 16),
                  onPressed: () => _deleteComment(postId, commentId),
                  tooltip: 'Delete Comment',
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          if (isEditing)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: commentEditControllers[commentId],
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.check, size: 16),
                  onPressed: () => _editComment(postId, commentId, commentEditControllers[commentId]!.text),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    setState(() {
                      commentEditing[commentId] = false;
                    });
                  },
                ),
              ],
            )
          else
            Text(comment['text'] ?? ''),
          if (comment['edited'] ?? false)
            const Text(
              'edited',
              style: TextStyle(fontSize: 10, color: Colors.grey),
            ),
        ],
      ),
    );
  }
}