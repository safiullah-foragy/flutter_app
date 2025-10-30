import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:chewie/chewie.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import 'app_cache_manager.dart';
import 'supabase.dart' as sb;

class NotebookListPage extends StatefulWidget {
  const NotebookListPage({super.key});

  @override
  State<NotebookListPage> createState() => _NotebookListPageState();
}

class _NotebookListPageState extends State<NotebookListPage> {
  final _auth = FirebaseAuth.instance;
  final _firestore = FirebaseFirestore.instance;

  Future<void> _createNotebook() async {
    final user = _auth.currentUser;
    if (user == null) return;
    String title = '';
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Create Notebook'),
          content: TextField(
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Notebook title'),
            onChanged: (v) => title = v,
            onSubmitted: (v) {
              title = v;
              Navigator.of(ctx).pop();
            },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Create')),
          ],
        );
      },
    );
    if (!mounted) return;
    title = title.trim().isEmpty ? 'Untitled' : title.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final doc = await _firestore.collection('notebooks').add({
        'user_id': user.uid,
        'title': title,
        'created_at': now,
        'updated_at': now,
      });
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => NotebookEditorPage(notebookId: doc.id)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create notebook: $e')),
      );
    }
  }

  Future<void> _deleteNotebook(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete notebook?'),
        content: const Text('This will remove the notebook and its items.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;

    // Delete items subcollection first (best-effort)
    try {
      final items = await _firestore.collection('notebooks').doc(id).collection('items').get();
      final batch = _firestore.batch();
      for (final d in items.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();
    } catch (_) {}

    try {
      await _firestore.collection('notebooks').doc(id).delete();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  Future<void> _renameNotebook(String id, String current) async {
    String title = current;
    await showDialog(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController(text: current);
        return AlertDialog(
          title: const Text('Rename Notebook'),
          content: TextField(
            controller: controller,
            autofocus: true,
            onChanged: (v) => title = v,
            onSubmitted: (v) {
              title = v;
              Navigator.of(ctx).pop();
            },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Save')),
          ],
        );
      },
    );
    title = title.trim();
    if (title.isEmpty || title == current) return;
    try {
      await _firestore.collection('notebooks').doc(id).update({
        'title': title,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rename failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Not signed in')));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notebooks'),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNotebook,
        child: const Icon(Icons.note_add),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('notebooks')
            .where('user_id', isEqualTo: user.uid)
            .orderBy('updated_at', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Can\'t load notebooks. Please check Firestore rules or App Check settings.\n\nError: ${snap.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final docs = snap.data?.docs ?? [];
          if (docs.isEmpty) {
            return const Center(child: Text('No notebooks yet. Tap + to create.'));
          }
          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) {
              final d = docs[i];
              final data = d.data() as Map<String, dynamic>?;
              final title = (data?['title'] ?? 'Untitled') as String;
              final updated = (data?['updated_at'] ?? 0) as int;
              final updatedStr = updated > 0
                  ? DateFormat('MMM dd, yyyy HH:mm').format(DateTime.fromMillisecondsSinceEpoch(updated))
                  : '';
              return ListTile(
                title: Text(title),
                subtitle: updatedStr.isNotEmpty ? Text('Updated: $updatedStr') : null,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => NotebookEditorPage(notebookId: d.id))),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'rename') _renameNotebook(d.id, title);
                    if (v == 'delete') _deleteNotebook(d.id);
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(value: 'rename', child: Text('Rename')),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class NotebookEditorPage extends StatefulWidget {
  final String notebookId;
  const NotebookEditorPage({super.key, required this.notebookId});

  @override
  State<NotebookEditorPage> createState() => _NotebookEditorPageState();
}

class _NotebookEditorPageState extends State<NotebookEditorPage> {
  final _firestore = FirebaseFirestore.instance;
  final _picker = ImagePicker();

  final Map<String, VideoPlayerController?> _videoPlayers = {};
  final Map<String, ChewieController?> _chewies = {};
  final Set<String> _videoInitInProgress = {};

  Timer? _titleDebounce;
  String _title = '';

  @override
  void dispose() {
    _titleDebounce?.cancel();
    for (final c in _chewies.values) {
      c?.dispose();
    }
    for (final v in _videoPlayers.values) {
      v?.dispose();
    }
    super.dispose();
  }

  Future<void> _updateTitle(String title) async {
    _titleDebounce?.cancel();
    _titleDebounce = Timer(const Duration(milliseconds: 600), () async {
      await _firestore.collection('notebooks').doc(widget.notebookId).update({
        'title': title.trim().isEmpty ? 'Untitled' : title.trim(),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  Future<void> _addTextItem() async {
    String text = '';
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Text'),
        content: TextField(
          autofocus: true,
          maxLines: null,
          onChanged: (v) => text = v,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Add')),
        ],
      ),
    );
    text = text.trim();
    if (text.isEmpty) return;
    await _firestore
        .collection('notebooks')
        .doc(widget.notebookId)
        .collection('items')
        .add({
      'type': 'text',
      'text': text,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    await _touchNotebook();
  }

  Future<void> _addImageItem() async {
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 1600);
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      final filename = picked.name.isNotEmpty ? picked.name : 'image_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final url = await sb.uploadNotebookImageBytes(bytes, fileName: filename);

      await _firestore
          .collection('notebooks')
          .doc(widget.notebookId)
          .collection('items')
          .add({
        'type': 'image',
        'url': url,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      await _touchNotebook();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Image upload failed: $e')));
    }
  }

  Future<void> _addVideoItem() async {
    try {
      final picked = await _picker.pickVideo(source: ImageSource.gallery);
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      final filename = picked.name.isNotEmpty ? picked.name : 'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final url = await sb.uploadNotebookVideoBytes(bytes, fileName: filename, contentType: 'video/mp4');

      await _firestore
          .collection('notebooks')
          .doc(widget.notebookId)
          .collection('items')
          .add({
        'type': 'video',
        'url': url,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      await _touchNotebook();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Video upload failed: $e')));
    }
  }

  Future<void> _touchNotebook() async {
    await _firestore.collection('notebooks').doc(widget.notebookId).update({
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _deleteItem(String id) async {
    await _firestore
        .collection('notebooks')
        .doc(widget.notebookId)
        .collection('items')
        .doc(id)
        .delete();
    await _touchNotebook();
  }

  Future<void> _saveTextItem(String id, String text) async {
    await _firestore
        .collection('notebooks')
        .doc(widget.notebookId)
        .collection('items')
        .doc(id)
        .update({'text': text});
    await _touchNotebook();
  }

  Future<void> _initVideo(String itemId, String url) async {
    if (_chewies[itemId] != null || _videoPlayers[itemId] != null) return;
    if (_videoInitInProgress.contains(itemId)) return;
    _videoInitInProgress.add(itemId);
    try {
      final v = VideoPlayerController.networkUrl(Uri.parse(url));
      await v.initialize();
      final chewie = ChewieController(
        videoPlayerController: v,
        autoInitialize: true,
        autoPlay: false,
        looping: false,
        allowMuting: true,
      );
      _videoPlayers[itemId] = v;
      _chewies[itemId] = chewie;
      if (mounted) setState(() {});
    } catch (_) {
      _videoPlayers[itemId]?.dispose();
      _videoPlayers.remove(itemId);
      _chewies[itemId]?.dispose();
      _chewies.remove(itemId);
    } finally {
      _videoInitInProgress.remove(itemId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: StreamBuilder<DocumentSnapshot>(
          stream: _firestore.collection('notebooks').doc(widget.notebookId).snapshots(),
          builder: (context, snap) {
            final data = snap.data?.data() as Map<String, dynamic>?;
            _title = (data?['title'] ?? 'Untitled') as String;
            return TextField(
              controller: TextEditingController(text: _title),
              decoration: const InputDecoration(border: InputBorder.none),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
              cursorColor: Colors.white,
              onChanged: _updateTitle,
            );
          },
        ),
        actions: [
          IconButton(onPressed: _addTextItem, icon: const Icon(Icons.text_fields)),
          IconButton(onPressed: _addImageItem, icon: const Icon(Icons.image)),
          IconButton(onPressed: _addVideoItem, icon: const Icon(Icons.videocam)),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('notebooks')
            .doc(widget.notebookId)
            .collection('items')
            .orderBy('timestamp')
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data?.docs ?? [];
          if (items.isEmpty) {
            return const Center(child: Text('Notebook is empty. Use the icons above to add content.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: items.length,
            itemBuilder: (ctx, i) {
              final d = items[i];
              final data = d.data() as Map<String, dynamic>?;
              final type = (data?['type'] ?? '') as String;
              if (type == 'text') {
                final controller = TextEditingController(text: (data?['text'] ?? '') as String);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          maxLines: null,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            hintText: 'Write something...',
                          ),
                          onSubmitted: (v) => _saveTextItem(d.id, v),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _deleteItem(d.id),
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                      ),
                    ],
                  ),
                );
              } else if (type == 'image') {
                final url = (data?['url'] ?? '') as String;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CachedNetworkImage(
                        imageUrl: url,
                        cacheManager: AppCacheManager.instance,
                        placeholder: (c, _) => const SizedBox(height: 200, child: Center(child: CircularProgressIndicator())),
                        errorWidget: (c, _, __) => const SizedBox(height: 200, child: Center(child: Icon(Icons.error))),
                        fit: BoxFit.cover,
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          onPressed: () => _deleteItem(d.id),
                          icon: const Icon(Icons.delete, color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                );
              } else if (type == 'video') {
                final url = (data?['url'] ?? '') as String;
                if (_chewies[d.id] == null && !_videoInitInProgress.contains(d.id)) {
                  _initVideo(d.id, url);
                }
                final chewie = _chewies[d.id];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 220,
                        child: chewie == null
                            ? const Center(child: CircularProgressIndicator())
                            : Chewie(controller: chewie),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          onPressed: () => _deleteItem(d.id),
                          icon: const Icon(Icons.delete, color: Colors.redAccent),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          );
        },
      ),
    );
  }
}

//
