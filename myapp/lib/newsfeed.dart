import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:permission_handler/permission_handler.dart';
import 'supabase.dart' as sb;
import 'see_profile_from_newsfeed.dart';

class NewsfeedPage extends StatefulWidget {
  const NewsfeedPage({super.key});

  @override
  State<NewsfeedPage> createState() => _NewsfeedPageState();
}

class _NewsfeedPageState extends State<NewsfeedPage> with SingleTickerProviderStateMixin {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ImagePicker _imagePicker = ImagePicker();
  final TextEditingController _postController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();

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
  Map<String, ChewieController?> videoControllers = {};
  Map<String, AnimationController?> likeAnimationControllers = {};
  StreamSubscription<QuerySnapshot>? _postsSubscription;
  Map<String, StreamSubscription<QuerySnapshot>?> commentSubscriptions = {};
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
    _fetchInitialPosts();
    _setupPostsListener();
  }

  @override
  void dispose() {
    _postController.dispose();
    _commentController.dispose();
    commentEditControllers.forEach((_, controller) => controller.dispose());
    videoControllers.forEach((_, controller) => controller?.dispose());
    likeAnimationControllers.forEach((_, controller) => controller?.dispose());
    _postsSubscription?.cancel();
    commentSubscriptions.forEach((_, sub) => sub?.cancel());
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
      }
    } catch (e) {
      print('Error requesting permission: $e');
      Fluttertoast.showToast(msg: 'Error requesting permission: $e');
    }
  }

  Future<void> _fetchUserData() async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        Fluttertoast.showToast(msg: 'User not logged in');
        return;
      }
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(user.uid).get();
      if (userDoc.exists) {
        setState(() {
          userData = userDoc.data() as Map<String, dynamic>?;
          userCache[user.uid] = userData;
        });
      } else {
        Fluttertoast.showToast(msg: 'User data not found');
      }
    } catch (e) {
      print('Error fetching user data: $e');
      Fluttertoast.showToast(msg: 'Failed to load user data: $e');
    }
  }

  Future<void> _fetchInitialPosts() async {
    try {
      QuerySnapshot postsSnapshot = await _firestore
          .collection('posts')
          .where('is_private', isEqualTo: false)
          .orderBy('timestamp', descending: true)
          .limit(20)
          .get();

      List<Map<String, dynamic>> postsList = [];
      for (var doc in postsSnapshot.docs) {
        Map<String, dynamic> postData = doc.data() as Map<String, dynamic>;
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

        setState(() {
          postLikes[postId] = postData['likes_count'] ?? 0;
          postCommentCounts[postId] = postData['comments_count'] ?? 0;
          userReactions[postId] = userReaction;
        });

        if (postData['video_url']?.isNotEmpty ?? false) {
          final videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(postData['video_url']));
          await videoPlayerController.initialize();
          videoControllers[postId] = ChewieController(
            videoPlayerController: videoPlayerController,
            autoPlay: false,
            looping: false,
            aspectRatio: videoPlayerController.value.aspectRatio,
            allowMuting: true,
            errorBuilder: (context, errorMessage) => Center(child: Text('Video error: $errorMessage')),
          );
        }
      }

      setState(() {
        posts = postsList;
        isLoading = false;
      });
    } catch (e) {
      print('Error fetching initial posts: $e');
      Fluttertoast.showToast(msg: 'Failed to load posts: $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  void _setupPostsListener() {
    _postsSubscription?.cancel();
    _postsSubscription = _firestore
        .collection('posts')
        .where('is_private', isEqualTo: false)
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots()
        .listen((snapshot) async {
      try {
        List<Map<String, dynamic>> postsList = [];
        for (var doc in snapshot.docs) {
          Map<String, dynamic> postData = doc.data() as Map<String, dynamic>;
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

          setState(() {
            postLikes[postId] = postData['likes_count'] ?? 0;
            postCommentCounts[postId] = postData['comments_count'] ?? 0;
            userReactions[postId] = userReaction;
          });

          if (postData['video_url']?.isNotEmpty ?? false && videoControllers[postId] == null) {
            final videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(postData['video_url']));
            await videoPlayerController.initialize();
            videoControllers[postId] = ChewieController(
              videoPlayerController: videoPlayerController,
              autoPlay: false,
              looping: false,
              aspectRatio: videoPlayerController.value.aspectRatio,
              allowMuting: true,
              errorBuilder: (context, errorMessage) => Center(child: Text('Video error: $errorMessage')),
            );
          }
        }

        setState(() {
          posts = postsList;
          isLoading = false;
        });
      } catch (e) {
        print('Error processing posts snapshot: $e');
        Fluttertoast.showToast(msg: 'Error loading posts: $e');
      }
    }, onError: (e) {
      print('Error in posts listener: $e');
      Fluttertoast.showToast(msg: 'Failed to load posts: $e');
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
      Fluttertoast.showToast(msg: 'Failed to load comments: $e');
      setState(() {
        postComments[postId] = [];
      });
    }
  }

  Future<void> _createPost() async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        Fluttertoast.showToast(msg: 'User not logged in');
        return;
      }
      if (_postController.text.isEmpty && _selectedImage == null && _selectedVideo == null) {
        Fluttertoast.showToast(msg: 'Please add content to post');
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
        final status = await Permission.videos.status;
        if (!status.isGranted) {
          await _requestPermissions(Permission.videos);
          if (!await Permission.videos.isGranted) return;
        }
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

      Fluttertoast.showToast(msg: 'Post created successfully');
    } catch (e) {
      print('Error creating post: $e');
      Fluttertoast.showToast(msg: 'Error creating post: $e');
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
      Fluttertoast.showToast(msg: 'Error picking image: $e');
    }
  }

  Future<void> _pickVideo() async {
    try {
      final status = await Permission.videos.status;
      if (!status.isGranted) {
        await _requestPermissions(Permission.videos);
        if (!await Permission.videos.isGranted) return;
      }

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
      Fluttertoast.showToast(msg: 'Error picking video: $e');
    }
  }

  Future<void> _addComment(String postId) async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        Fluttertoast.showToast(msg: 'User not logged in');
        return;
      }
      if (_commentController.text.isEmpty) {
        Fluttertoast.showToast(msg: 'Please write a comment');
        return;
      }

      final int timestamp = DateTime.now().millisecondsSinceEpoch;
      DocumentReference ref = await _firestore
          .collection('posts')
          .doc(postId)
          .collection('comments')
          .add({
        'user_id': user.uid,
        'text': _commentController.text,
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
          'text': _commentController.text,
          'timestamp': timestamp,
          'user_data': userData,
        });
        postCommentCounts[postId] = (postCommentCounts[postId] ?? 0) + 1;
        _commentController.clear();
      });

      Fluttertoast.showToast(msg: 'Comment added');
    } catch (e) {
      print('Error adding comment: $e');
      Fluttertoast.showToast(msg: 'Error adding comment: $e');
    }
  }

  Future<void> _editComment(String postId, String commentId, String newText) async {
    try {
      if (newText.isEmpty) {
        Fluttertoast.showToast(msg: 'Comment cannot be empty');
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

      Fluttertoast.showToast(msg: 'Comment updated');
    } catch (e) {
      print('Error updating comment: $e');
      Fluttertoast.showToast(msg: 'Error updating comment: $e');
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

      Fluttertoast.showToast(msg: 'Comment deleted');
    } catch (e) {
      print('Error deleting comment: $e');
      Fluttertoast.showToast(msg: 'Error deleting comment: $e');
    }
  }

  Future<void> _toggleLike(String postId, String reaction) async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) {
        Fluttertoast.showToast(msg: 'User not logged in');
        return;
      }

      final docRef = _firestore
          .collection('posts')
          .doc(postId)
          .collection('likes')
          .doc(user.uid);

      DocumentSnapshot likeDoc = await docRef.get();

      if (likeDoc.exists && userReactions[postId] == reaction) {
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
          if (!likeDoc.exists) {
            postLikes[postId] = (postLikes[postId] ?? 0) + 1;
          }
          likeAnimationControllers[postId]?.forward(from: 0);
        });
        if (!likeDoc.exists) {
          await _firestore.collection('posts').doc(postId).update({
            'likes_count': FieldValue.increment(1),
          });
        }
      }
    } catch (e) {
      print('Error toggling like: $e');
      Fluttertoast.showToast(msg: 'Failed to update like: $e');
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true, // Allow back navigation
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Newsfeed'),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          toolbarHeight: 40,
        ),
        body: Column(
          children: [
            SizedBox(
              height: 100,
              child: Card(
                margin: const EdgeInsets.all(8.0),
                child: Padding(
                  padding: const EdgeInsets.all(6.0),
                  child: Column(
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
                          } else {
                            Fluttertoast.showToast(msg: 'User not logged in');
                          }
                        },
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 15,
                              backgroundColor: Colors.grey[300],
                              backgroundImage: userData?['profile_image'] != null
                                  ? CachedNetworkImageProvider(userData!['profile_image'])
                                  : null,
                              child: userData?['profile_image'] == null
                                  ? const Icon(Icons.person, size: 15, color: Colors.grey)
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              userData?['name'] ?? 'User',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 36,
                              child: TextField(
                                controller: _postController,
                                maxLines: 1,
                                decoration: InputDecoration(
                                  hintText: "What's on your mind?",
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            icon: const Icon(Icons.photo_library, size: 18),
                            onPressed: _pickImage,
                            tooltip: 'Add Photo',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          IconButton(
                            icon: const Icon(Icons.video_library, size: 18),
                            onPressed: _pickVideo,
                            tooltip: 'Add Video',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                          IconButton(
                            icon: const Icon(Icons.send, size: 18),
                            onPressed: _createPost,
                            tooltip: 'Post',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      if (_selectedImage != null || _selectedVideo != null)
                        SizedBox(
                          height: 50,
                          child: Row(
                            children: [
                              if (_selectedImage != null) Expanded(child: Image.file(_selectedImage!)),
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
            ),
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : posts.isEmpty
                      ? const Center(child: Text('No posts available'))
                      : ListView.builder(
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
                      Text(
                        DateFormat('MMM dd, yyyy - HH:mm').format(
                          DateTime.fromMillisecondsSinceEpoch(post['timestamp'] ?? 0),
                        ),
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
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
              ),
            if (post['video_url']?.isNotEmpty ?? false)
              SizedBox(
                height: 200,
                child: videoControllers[postId] != null
                    ? Chewie(controller: videoControllers[postId]!)
                    : const Center(child: CircularProgressIndicator()),
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
                  onTap: () {
                    if (userReaction.isEmpty) {
                      _toggleLike(postId, 'like');
                    }
                  },
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
                        Icon(
                          Icons.thumb_up,
                          color: userReaction.isNotEmpty ? Colors.blue : Colors.grey,
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
                    bool wasExpanded = expandedComments[postId] ?? false;
                    setState(() {
                      expandedComments[postId] = !wasExpanded;
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
                        Fluttertoast.showToast(msg: 'Error loading comments: $e');
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
                  child: const Row(
                    children: [
                      Icon(Icons.comment, color: Colors.grey),
                      SizedBox(width: 5),
                      Text('Comment', style: TextStyle(color: Colors.grey)),
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
                        controller: _commentController,
                        decoration: const InputDecoration(
                          hintText: 'Write a comment...',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 10),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () => _addComment(postId),
                    ),
                  ],
                ),
              ),
              postComments[postId] == null
                  ? const Center(child: CircularProgressIndicator())
                  : postComments[postId]!.isEmpty
                      ? const Text('No comments yet')
                      : Column(
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