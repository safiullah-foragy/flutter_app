import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:permission_handler/permission_handler.dart';
import 'login.dart';
import 'newsfeed.dart';
import 'ProfileImagesPage.dart';
import 'package:intl/intl.dart';
import 'supabase.dart' as sb;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ImagePicker _imagePicker = ImagePicker();
  final Connectivity _connectivity = Connectivity();
  Map<String, dynamic>? userData;
  bool isLoading = true;
  bool isUploading = false;
  final Map<String, TextEditingController> _controllers = {};
  StreamSubscription<DocumentSnapshot>? _userSubscription;
  
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;
  List<Map<String, dynamic>> userPosts = [];
  Map<String, List<Map<String, dynamic>>> postComments = {};
  Map<String, int> postLikes = {};
  Map<String, int> postCommentCounts = {};
  Map<String, String> userReactions = {};
  Map<String, bool> commentEditing = {};
  Map<String, TextEditingController> commentEditControllers = {};
  Map<String, bool> expandedComments = {};
  Map<String, Map<String, dynamic>?> userCache = {};
  Map<String, VideoPlayerController?> videoPlayerControllers = {};
  Map<String, ChewieController?> videoControllers = {};
  // Track init state and failures for videos to prevent endless spinners
  Set<String> videoInitInProgress = {};
  Map<String, String> videoInitErrors = {};
  // Cache resolved (possibly signed) video URLs by original URL to avoid repeated signing.
  static final Map<String, String> _resolvedVideoUrlCache = {};
  Map<String, AnimationController?> likeAnimationControllers = {};
  StreamSubscription<QuerySnapshot>? _postsSubscription;
  Map<String, StreamSubscription<QuerySnapshot>?> commentSubscriptions = {};
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;
  bool hasConnection = true;
  Map<String, TextEditingController> perPostCommentControllers = {};

  @override
  void initState() {
    super.initState();
    try {
      _firestore.settings = const Settings(persistenceEnabled: true);
    } catch (_) {
      try {
        _firestore.settings = const Settings(persistenceEnabled: false);
      } catch (_) {}
    }
    _checkConnectivity();
    _fetchUserData();
    _setupUserListener();
    _updateLastLogin();
    _fetchInitialUserPosts();
    _setupPostsListener();
    
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));
    
    Future.delayed(const Duration(milliseconds: 500), () {
      _animationController.forward();
    });
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
    _animationController.dispose();
    _controllers.forEach((key, controller) {
      controller.dispose();
    });
    perPostCommentControllers.forEach((_, c) => c.dispose());
    commentEditControllers.forEach((_, controller) => controller.dispose());
    videoControllers.forEach((_, controller) => controller?.dispose());
    videoPlayerControllers.forEach((_, controller) => controller?.dispose());
    likeAnimationControllers.forEach((_, controller) => controller?.dispose());
    _userSubscription?.cancel();
    _postsSubscription?.cancel();
    commentSubscriptions.forEach((_, sub) => sub?.cancel());
    _connectivitySubscription?.cancel();
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
    }
  }

  Future<void> _updateLastLogin() async {
    final User? user = _auth.currentUser;
    if (user != null) {
      await _firestore.collection('users').doc(user.uid).update({
        'last_login': DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
      });
    }
  }

  Future<void> _fetchUserData() async {
    try {
      final User? user = _auth.currentUser;
      if (user != null) {
        DocumentSnapshot userDoc = 
            await _firestore.collection('users').doc(user.uid).get();
            
        if (userDoc.exists) {
          setState(() {
            userData = userDoc.data() as Map<String, dynamic>;
            
            _controllers['name'] = TextEditingController(text: userData?['name'] ?? '');
            _controllers['dob'] = TextEditingController(text: userData?['dob'] ?? '');
            _controllers['current_job'] = TextEditingController(text: userData?['current_job'] ?? '');
            _controllers['experience'] = TextEditingController(text: userData?['experience'] ?? '');
            _controllers['session'] = TextEditingController(text: userData?['session'] ?? '');
            
            isLoading = false;
          });
        }
      }
    } catch (e) {
      print('Error fetching user data: $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  void _setupUserListener() {
    final user = _auth.currentUser;
    if (user == null) return;
    _userSubscription?.cancel();
    _userSubscription = _firestore.collection('users').doc(user.uid).snapshots().listen(
      (doc) {
        if (!doc.exists) return;
        final data = doc.data();
        if (data == null) return;
        setState(() {
          userData = data;
          // Keep bound text fields in sync
          _controllers['name'] ??= TextEditingController();
          _controllers['dob'] ??= TextEditingController();
          _controllers['current_job'] ??= TextEditingController();
          _controllers['experience'] ??= TextEditingController();
          _controllers['session'] ??= TextEditingController();
          _controllers['name']!.text = data['name'] ?? '';
          _controllers['dob']!.text = data['dob'] ?? '';
          _controllers['current_job']!.text = data['current_job'] ?? '';
          _controllers['experience']!.text = data['experience'] ?? '';
          _controllers['session']!.text = data['session'] ?? '';
          isLoading = false;
        });
      },
      onError: (e) => print('User listener error: $e'),
    );
  }

  Future<void> _fetchInitialUserPosts() async {
    if (!hasConnection) {
      setState(() {});
      return;
    }
    try {
      final User? user = _auth.currentUser;
      if (user == null) return;
      QuerySnapshot postsSnapshot;
      final orderedQuery = _firestore
          .collection('posts')
          .where('user_id', isEqualTo: user.uid)
          .orderBy('timestamp', descending: true);
      try {
        // Cache first for instant UI
        postsSnapshot = await orderedQuery.get(const GetOptions(source: Source.cache));
        if (postsSnapshot.docs.isEmpty) {
          // If cache empty, try server
          postsSnapshot = await orderedQuery.get();
        }
      } catch (e) {
        // Fallback without orderBy; sort client-side
        try {
          postsSnapshot = await _firestore
              .collection('posts')
              .where('user_id', isEqualTo: user.uid)
              .get(const GetOptions(source: Source.cache));
          if (postsSnapshot.docs.isEmpty) {
            postsSnapshot = await _firestore
                .collection('posts')
                .where('user_id', isEqualTo: user.uid)
                .get();
          }
        } catch (_) {
          postsSnapshot = await _firestore
              .collection('posts')
              .where('user_id', isEqualTo: user.uid)
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
          Map<String, dynamic>? postUserData;
          if (userCache.containsKey(userId)) {
            postUserData = userCache[userId];
          } else {
            DocumentSnapshot userDoc = await _firestore.collection('users').doc(userId).get();
            if (userDoc.exists) {
              postUserData = userDoc.data() as Map<String, dynamic>;
              userCache[userId] = postUserData;
            }
          }

          DocumentSnapshot likesDoc = await _firestore
              .collection('posts')
              .doc(postId)
              .collection('likes')
              .doc(_auth.currentUser?.uid)
              .get();

          String userReaction = likesDoc.exists ? (likesDoc.get('reaction') ?? 'like') : '';

          postsList.add({
            'id': postId,
            ...postData,
            'user_data': postUserData,
          });

          postLikes[postId] = postData['likes_count'] ?? 0;
          postCommentCounts[postId] = postData['comments_count'] ?? 0;
          userReactions[postId] = userReaction;

          if ((postData['video_url'] as String?)?.isNotEmpty ?? false) {
            videoPlayerControllers[postId] = null;
            videoControllers[postId] = null;
          }
        } catch (postError) {
          print('Error processing post ${doc.id}: $postError');
        }
      }

      // Ensure newest first if fallback path used
      postsList.sort((a, b) => ((b['timestamp'] ?? 0) as int).compareTo((a['timestamp'] ?? 0) as int));
      postsList.sort((a, b) => ((b['timestamp'] ?? 0) as int).compareTo((a['timestamp'] ?? 0) as int));
      setState(() {
        userPosts = postsList;
      });
    } catch (e) {
      print('Error fetching initial posts: $e');
      setState(() {});
    }
  }

  void _setupPostsListener() {
    _postsSubscription?.cancel();
    final User? user = _auth.currentUser;
    if (user == null) return;
    // Helper to process snapshot docs into local state
    Future<void> process(QuerySnapshot snapshot) async {
      // Allow cached data to show even if offline; if online, proceed normally
      List<Map<String, dynamic>> postsList = [];
      for (var doc in snapshot.docs) {
        try {
          final postData = doc.data() as Map<String, dynamic>?;
          if (postData == null) continue;
          String postId = doc.id;

          String userId = postData['user_id'] ?? '';
          Map<String, dynamic>? postUserData;
          if (userCache.containsKey(userId)) {
            postUserData = userCache[userId];
          } else {
            DocumentSnapshot userDoc = await _firestore.collection('users').doc(userId).get();
            if (userDoc.exists) {
              postUserData = userDoc.data() as Map<String, dynamic>;
              userCache[userId] = postUserData;
            }
          }

          // Reaction state for current user
          try {
            final likesDoc = await _firestore
                .collection('posts')
                .doc(postId)
                .collection('likes')
                .doc(_auth.currentUser?.uid)
                .get();
            String userReaction = likesDoc.exists ? (likesDoc.get('reaction') ?? 'like') : '';
            userReactions[postId] = userReaction;
          } catch (_) {}

          postsList.add({
            'id': postId,
            ...postData,
            'user_data': postUserData,
          });

          postLikes[postId] = postData['likes_count'] ?? 0;
          postCommentCounts[postId] = postData['comments_count'] ?? 0;
        } catch (postError) {
          print('Error processing post ${doc.id}: $postError');
        }
      }

      // If the query below falls back without orderBy, ensure newest first
      postsList.sort((a, b) => ((b['timestamp'] ?? 0) as int).compareTo((a['timestamp'] ?? 0) as int));

      setState(() {
        userPosts = postsList;
      });
    }

    // Primary: ordered stream (needs composite index sometimes)
    try {
      _postsSubscription = _firestore
          .collection('posts')
          .where('user_id', isEqualTo: user.uid)
          .orderBy('timestamp', descending: true)
          .snapshots(includeMetadataChanges: true)
          .listen((snapshot) async {
        await process(snapshot);
      }, onError: (e) async {
        print('Ordered posts listener error: $e');
        // Fallback: unordered stream then sort client-side
        _postsSubscription?.cancel();
        _postsSubscription = _firestore
            .collection('posts')
            .where('user_id', isEqualTo: user.uid)
            .snapshots(includeMetadataChanges: true)
            .listen((snapshot) async {
          await process(snapshot);
        }, onError: (err) => print('Unordered posts listener error: $err'));
      });
    } catch (e) {
      // If building the query itself throws (e.g., missing index), fallback
      print('Setting ordered listener threw: $e');
      _postsSubscription = _firestore
          .collection('posts')
          .where('user_id', isEqualTo: user.uid)
          .snapshots(includeMetadataChanges: true)
          .listen((snapshot) async {
        await process(snapshot);
      }, onError: (err) => print('Unordered posts listener error: $err'));
    }
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
      setState(() {
        postComments[postId] = [];
      });
    }
  }

  Future<void> _addComment(String postId, TextEditingController controller) async {
    try {
      final User? user = _auth.currentUser;
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
    }
  }

  Future<void> _toggleLike(String postId, String reaction) async {
    try {
      final User? user = _auth.currentUser;
      if (user == null) {
        return;
      }

      final docRef = _firestore
          .collection('posts')
          .doc(postId)
          .collection('likes')
          .doc(user.uid);

      DocumentSnapshot likeDoc = await docRef.get();
      bool wasLiked = likeDoc.exists;
      String oldReaction = wasLiked ? (likeDoc.get('reaction') ?? 'like') : '';

      if (wasLiked && oldReaction == reaction) {
        await docRef.delete();
        setState(() {
          userReactions[postId] = '';
          postLikes[postId] = (postLikes[postId] ?? 1) - 1;
        });
        await _firestore.collection('posts').doc(postId).update({
          'likes_count': FieldValue.increment(-1),
        });
      } else {
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
    }
  }

  void _showReactionOptions(String postId) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildReactionButton('❤️', 'love', postId),
              _buildReactionButton('😊', 'like', postId),
              _buildReactionButton('😢', 'sad', postId),
              _buildReactionButton('😠', 'angry', postId),
            ],
          ),
        );
      },
    );
  }

  Future<void> _initVideoControllers(String postId, String url) async {
    if (url.isEmpty) return;
    try {
      if (videoPlayerControllers[postId] != null || videoControllers[postId] != null) return;
      if (videoInitInProgress.contains(postId)) return; // avoid duplicate inits
      videoInitErrors.remove(postId);
      videoInitInProgress.add(postId);
      // Prefer a signed Supabase URL up-front for Supabase-hosted videos to avoid 403/redirect latency.
      String attemptUrl = url;
      if (url.contains('/storage/v1/object/public/')) {
        final signedFirst = _resolvedVideoUrlCache[url] ?? await _trySignedSupabaseUrl(url);
        if (signedFirst != null) {
          attemptUrl = signedFirst;
          _resolvedVideoUrlCache[url] = signedFirst;
        }
      }
      VideoPlayerController vpc = VideoPlayerController.networkUrl(Uri.parse(attemptUrl));
      videoPlayerControllers[postId] = vpc;
      try {
        await vpc.initialize().timeout(const Duration(seconds: 15));
      } catch (e) {
        final signed = _resolvedVideoUrlCache[url] ?? await _trySignedSupabaseUrl(url);
        if (signed != null) {
          try { await vpc.dispose(); } catch (_) {}
          attemptUrl = signed;
          _resolvedVideoUrlCache[url] = signed;
          vpc = VideoPlayerController.networkUrl(Uri.parse(attemptUrl));
          videoPlayerControllers[postId] = vpc;
          await vpc.initialize().timeout(const Duration(seconds: 15));
        } else {
          rethrow;
        }
      }

      final chewie = ChewieController(
        videoPlayerController: vpc,
        autoInitialize: true,
        autoPlay: false,
        looping: false,
        allowMuting: true,
        errorBuilder: (context, errorMessage) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.red),
              const SizedBox(height: 8),
              Text('Video error: ' + errorMessage),
            ],
          ),
        ),
      );

      videoControllers[postId] = chewie;
      if (mounted) setState(() {});
    } catch (e) {
      print('Error initializing video for $postId: $e');
      try {
        await videoPlayerControllers[postId]?.dispose();
      } catch (_) {}
      videoPlayerControllers[postId] = null;
      videoControllers[postId] = null;
      videoInitErrors[postId] = e.toString();
      if (mounted) setState(() {});
    } finally {
      videoInitInProgress.remove(postId);
    }
  }

  // Try to create a signed Supabase URL for public storage when direct URL fails.
  Future<String?> _trySignedSupabaseUrl(String url) async {
    try {
      const marker = '/storage/v1/object/public/';
      final idx = url.indexOf(marker);
      if (idx == -1) return null;
      final tail = url.substring(idx + marker.length);
      final parts = tail.split('/');
      if (parts.length < 2) return null;
      final bucket = parts[0];
      final objectPath = parts.sublist(1).join('/');
      final dynamic signed = await sb.supabase.storage.from(bucket).createSignedUrl(objectPath, 60 * 60);
      final String? signedUrl = signed?.toString();
      return signedUrl;
    } catch (_) {
      return null;
    }
  }

  // _validateUrlExists is no longer needed because we rely on player initialization
  // to determine accessibility and only fallback to a signed URL on failure.

  // _resolveVideoUrl deprecated; no longer used.

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

  Future<void> _updateField(String field, dynamic value) async {
    try {
      final User? user = _auth.currentUser;
      if (user != null) {
        await _firestore.collection('users').doc(user.uid).update({
          field: value,
        });
        
        setState(() {
          userData?[field] = value;
        });
        
        Fluttertoast.showToast(msg: '${_getFieldDisplayName(field)} updated successfully');
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error updating ${_getFieldDisplayName(field)}: $e');
    }
  }

  Future<void> _uploadProfileImage() async {
    try {
      // On web, permissions are handled by the browser; on mobile, request if needed
      if (!kIsWeb) {
        final status = await Permission.photos.status;
        if (!status.isGranted) {
          await _requestPermissions(Permission.photos);
          if (!await Permission.photos.isGranted) return;
        }
      }

      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 800,
        maxHeight: 800,
      );
      
      if (pickedFile != null) {
        setState(() {
          isUploading = true;
        });
        
        final User? user = _auth.currentUser;
        if (user != null) {
          // Use bytes-based upload for web compatibility
          final bytes = await pickedFile.readAsBytes();
          // Derive an extension/contentType
          String ext = '';
          try {
            ext = p.extension(pickedFile.name.isNotEmpty ? pickedFile.name : pickedFile.path);
          } catch (_) {
            ext = '.jpg';
          }
          if (ext.isEmpty) ext = '.jpg';
          String contentType = 'application/octet-stream';
          switch (ext.toLowerCase()) {
            case '.jpg':
            case '.jpeg':
              contentType = 'image/jpeg';
              break;
            case '.png':
              contentType = 'image/png';
              break;
            case '.gif':
              contentType = 'image/gif';
              break;
            case '.webp':
              contentType = 'image/webp';
              break;
          }
          final String fileName = '${user.uid}_${DateTime.now().millisecondsSinceEpoch}$ext';
          final String downloadUrl = await sb.uploadImageData(
            bytes,
            fileName: fileName,
            folder: 'profile-images',
            contentType: contentType,
          );
          
          await _updateField('profile_image', downloadUrl);
          
          Fluttertoast.showToast(msg: 'Profile image updated successfully');
        }
      }
    } catch (e) {
      print('Error uploading image: $e');
      Fluttertoast.showToast(msg: 'Error uploading image: $e');
    } finally {
      setState(() {
        isUploading = false;
      });
    }
  }

  void _showEditDialog(String field, String currentValue) {
    final controller = TextEditingController(text: currentValue);
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Edit ${_getFieldDisplayName(field)}'),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: 'Enter your ${_getFieldDisplayName(field).toLowerCase()}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  _updateField(field, controller.text.trim());
                }
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showDatePicker() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    
    if (pickedDate != null) {
      final formattedDate = DateFormat('yyyy-MM-dd').format(pickedDate);
      await _updateField('dob', formattedDate);
      setState(() {
        _controllers['dob']?.text = formattedDate;
      });
    }
  }

  String _getFieldDisplayName(String field) {
    switch (field) {
      case 'name': return 'Full Name';
      case 'dob': return 'Date of Birth';
      case 'current_job': return 'Current Job';
      case 'experience': return 'Experience';
      case 'session': return 'Session';
      case 'profile_image': return 'Profile Image';
      default: return field;
    }
  }

  Future<void> _deletePost(String postId) async {
    try {
      await _firestore.collection('posts').doc(postId).delete();
      Fluttertoast.showToast(msg: 'Post deleted successfully');
      setState(() {
        userPosts.removeWhere((post) => post['id'] == postId);
        postLikes.remove(postId);
        postCommentCounts.remove(postId);
        userReactions.remove(postId);
        postComments.remove(postId);
        expandedComments.remove(postId);
        if (perPostCommentControllers.containsKey(postId)) {
          perPostCommentControllers[postId]!.dispose();
          perPostCommentControllers.remove(postId);
        }
        if (videoPlayerControllers.containsKey(postId)) {
          videoPlayerControllers[postId]?.dispose();
          videoPlayerControllers.remove(postId);
        }
        if (videoControllers.containsKey(postId)) {
          videoControllers[postId]?.dispose();
          videoControllers.remove(postId);
        }
        if (likeAnimationControllers.containsKey(postId)) {
          likeAnimationControllers[postId]?.dispose();
          likeAnimationControllers.remove(postId);
        }
        if (commentSubscriptions.containsKey(postId)) {
          commentSubscriptions[postId]?.cancel();
          commentSubscriptions.remove(postId);
        }
      });
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error deleting post: $e');
    }
  }

  Future<void> _togglePostPrivacy(String postId, bool currentPrivacy) async {
    bool newPrivacy = !currentPrivacy;
    try {
      await _firestore.collection('posts').doc(postId).update({
        'is_private': newPrivacy,
      });
      Fluttertoast.showToast(msg: 'Post privacy updated to ${newPrivacy ? 'private' : 'public'}');
      setState(() {
        final post = userPosts.firstWhere((p) => p['id'] == postId);
        post['is_private'] = newPrivacy;
      });
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error updating post privacy: $e');
    }
  }

  Future<void> _editPost(String postId, String newText) async {
    try {
      if (newText.isEmpty) return;
      await _firestore.collection('posts').doc(postId).update({
        'text': newText,
      });
      setState(() {
        final post = userPosts.firstWhere((p) => p['id'] == postId);
        post['text'] = newText;
      });
      Fluttertoast.showToast(msg: 'Post updated successfully');
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error updating post: $e');
    }
  }

  void _showPostEditDialog(String postId, String currentText) {
    final controller = TextEditingController(text: currentText);
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Edit Post'),
          content: TextField(
            controller: controller,
            maxLines: null,
            decoration: const InputDecoration(
              hintText: 'Edit your post text',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  _editPost(postId, controller.text.trim());
                }
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Profile'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              try {
                await FirebaseAuth.instance.signOut();
                Navigator.pushReplacement(
                  context, 
                  MaterialPageRoute(builder: (_) => const LoginPage())
                );
              } catch (e) {
                Fluttertoast.showToast(
                  msg: 'Error signing out: $e',
                  toastLength: Toast.LENGTH_SHORT,
                  backgroundColor: Colors.red,
                );
              }
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await _fetchUserData();
                await _fetchInitialUserPosts();
              },
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Column(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.blue,
                                width: 4.0,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withOpacity(0.3),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Stack(
                              children: [
                                CircleAvatar(
                                  radius: 70,
                                  backgroundColor: Colors.grey[300],
                                  backgroundImage: userData?['profile_image'] != null
                                      ? CachedNetworkImageProvider(userData!['profile_image']) as ImageProvider
                                      : null,
                                  child: userData?['profile_image'] == null
                                      ? const Icon(Icons.person, size: 60, color: Colors.grey)
                                      : null,
                                ),
                                if (isUploading)
                                  Positioned.fill(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.5),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Center(
                                        child: CircularProgressIndicator(
                                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          
                          const SizedBox(height: 16),
                          
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const NewsfeedPage()),
                                  ).then((_) {
                                    _fetchInitialUserPosts();
                                  });
                                },
                                icon: const Icon(Icons.feed, size: 18),
                                label: const Text('Newsfeed'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15.0),
                                  ),
                                ),
                              ),
                              
                              const SizedBox(width: 16),
                              
                              ElevatedButton.icon(
                                onPressed: isUploading ? null : _uploadProfileImage,
                                icon: const Icon(Icons.camera_alt, size: 18),
                                label: const Text('Upload Photo'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.blue,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15.0),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          
                          const SizedBox(height: 16),
                          
                          SlideTransition(
                            position: _slideAnimation,
                            child: Text(
                              userData?['name'] ?? 'No Name Provided',
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: Color.fromARGB(255, 226, 146, 146),
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          
                          const SizedBox(height: 8),
                          
                          Text(
                            userData?['email'] ?? 'No Email Provided',
                            style: const TextStyle(
                              fontSize: 17,
                              color: Color.fromARGB(255, 60, 14, 14),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(height: 24),
                    
                    _buildSectionHeader('Personal Information'),
                    _buildEditableInfoItem('Full Name', userData?['name'] ?? 'Not provided', 'name'),
                    _buildInfoItem('Email', userData?['email'] ?? 'Not provided'),
                    _buildEditableInfoItem('Date of Birth', userData?['dob'] ?? 'Not provided', 'dob', isDate: true),
                    
                    _buildSectionHeader('Professional Information'),
                    _buildEditableInfoItem('Current Job', userData?['current_job'] ?? 'Not provided', 'current_job'),
                    _buildEditableInfoItem('Experience', userData?['experience'] ?? 'Not provided', 'experience'),
                    _buildEditableInfoItem('Session', userData?['session'] ?? 'Not provided', 'session'),
                    
                    _buildSectionHeader('Account Information'),
                    _buildInfoItem('User ID', user?.uid ?? 'Not available'),
                    _buildInfoItem('Account Created', userData?['created_at'] ?? 'Not available'),
                    _buildInfoItem('Last Login', userData?['last_login'] ?? 'Not available'),
                    
                    const SizedBox(height: 30),
                    
                    Center(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ProfileImagesPage()),
                          ).then((_) {
                            _fetchInitialUserPosts();
                          });
                        },
                        icon: const Icon(Icons.photo_library, size: 18),
                        label: const Text('All Media'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(15.0),
                          ),
                        ),
                      ),
                    ),
                    
                    const SizedBox(height: 30),
                    
                    if (userPosts.isNotEmpty) ...[
                      _buildSectionHeader('Your Posts'),
                      ...userPosts.map((post) => _buildPostItem(post)).toList(),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.blue,
        ),
      ),
    );
  }

  Widget _buildInfoItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: value == 'Not provided' || value == 'Not available' 
                    ? Colors.grey 
                    : Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableInfoItem(String label, String value, String field, {bool isDate = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: value == 'Not provided' ? Colors.grey : Colors.black,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 18, color: Colors.blue),
            onPressed: () {
              if (isDate) {
                _showDatePicker();
              } else {
                _showEditDialog(field, value);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPostItem(Map<String, dynamic> post) {
    final String postId = post['id'];
    final int likesCount = postLikes[postId] ?? 0;
    final int commentsCount = postCommentCounts[postId] ?? 0;
    final String userReaction = userReactions[postId] ?? '';

    if (!likeAnimationControllers.containsKey(postId)) {
      likeAnimationControllers[postId] = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  DateFormat('MMM dd, yyyy - HH:mm').format(
                    DateTime.fromMillisecondsSinceEpoch(post['timestamp'] ?? 0),
                  ),
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () => _showPostEditDialog(postId, post['text'] ?? ''),
                    ),
                    IconButton(
                      icon: Icon(
                        post['is_private'] ?? false ? Icons.lock_outline : Icons.public,
                        size: 18,
                      ),
                      onPressed: () => _togglePostPrivacy(postId, post['is_private'] ?? false),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, size: 18, color: Colors.red),
                      onPressed: () => _deletePost(postId),
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
                imageUrl: post['image_url'],
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
                  // If nothing initialized yet, kick it off once
                  if (videoControllers[postId] == null && videoPlayerControllers[postId] == null && !videoInitInProgress.contains(postId)) {
                    _initVideoControllers(postId, url);
                  }

                  if (videoControllers[postId] != null) {
                    final chewie = videoControllers[postId]!;
                    try {
                      if (chewie.videoPlayerController.value.isPlaying) {
                        chewie.videoPlayerController.pause();
                      }
                    } catch (_) {}
                    return Chewie(controller: chewie);
                  }

                  // Show progress while initializing
                  if (videoInitInProgress.contains(postId) || (videoPlayerControllers[postId] != null && !(videoPlayerControllers[postId]!.value.isInitialized))) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  // If we got here, init likely failed or URL invalid. Show retry UI.
                  final msg = videoInitErrors[postId];
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red),
                        const SizedBox(height: 8),
                        Text(msg == null || msg.isEmpty ? 'Video unavailable' : 'Video error: $msg', textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: () {
                            // Reset and retry
                            videoPlayerControllers[postId]?.dispose();
                            videoPlayerControllers.remove(postId);
                            videoControllers[postId]?.dispose();
                            videoControllers.remove(postId);
                            videoInitErrors.remove(postId);
                            _initVideoControllers(postId, url);
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
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