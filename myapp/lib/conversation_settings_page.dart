import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

/// Per-conversation notification and ringtone settings
class ConversationSettingsPage extends StatefulWidget {
  final String conversationId;
  final String otherUserId;
  final String otherUserName;

  const ConversationSettingsPage({
    required this.conversationId,
    required this.otherUserId,
    required this.otherUserName,
    super.key,
  });

  @override
  State<ConversationSettingsPage> createState() => _ConversationSettingsPageState();
}

class _ConversationSettingsPageState extends State<ConversationSettingsPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  AudioPlayer? _player;
  
  bool _loading = true;
  bool _previewing = false;
  List<String> _mp3Assets = [];
  
  String? _notificationSound;
  bool _notificationSilent = false;
  String? _callRingtone;
  bool _callRingtoneSilent = false;

  @override
  void initState() {
    super.initState();
    _loadAssets();
    _load();
  }

  @override
  void dispose() {
    _stopPreview();
    super.dispose();
  }

  Future<void> _loadAssets() async {
    try {
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);
      
      final mp3s = manifestMap.keys
          .where((k) => k.startsWith('assets/mp3 file/') && k.endsWith('.mp3'))
          .toList();
      setState(() => _mp3Assets = mp3s);
    } catch (e) {
      debugPrint('Error loading assets: $e');
    }
  }

  Future<void> _load() async {
    final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      final doc = await _firestore
          .collection('conversations')
          .doc(widget.conversationId)
          .get();

      if (doc.exists) {
        final data = doc.data() ?? {};
        final settings = data['settings'] as Map<String, dynamic>? ?? {};
        final userSettings = settings[uid] as Map<String, dynamic>? ?? {};

        // Default ringtones
        const defaultCall = 'assets/mp3 file/lovely-Alarm.mp3';
        const defaultMessage = 'assets/mp3 file/Iphone-Notification.mp3';

        setState(() {
          _notificationSound = userSettings['notification_sound'] as String?;
          if (_notificationSound == null || _notificationSound!.isEmpty) {
            _notificationSound = defaultMessage;
          }
          _notificationSilent = userSettings['notification_silent'] as bool? ?? false;
          
          _callRingtone = userSettings['call_ringtone'] as String?;
          if (_callRingtone == null || _callRingtone!.isEmpty) {
            _callRingtone = defaultCall;
          }
          _callRingtoneSilent = userSettings['call_ringtone_silent'] as bool? ?? false;
          _loading = false;
        });
      } else {
        // No settings exist yet, use defaults
        setState(() {
          _notificationSound = 'assets/mp3 file/Iphone-Notification.mp3';
          _callRingtone = 'assets/mp3 file/lovely-Alarm.mp3';
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading conversation settings: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      await _firestore.collection('conversations').doc(widget.conversationId).set({
        'settings': {
          uid: {
            'notification_sound': _notificationSound ?? '',
            'notification_silent': _notificationSilent,
            'call_ringtone': _callRingtone ?? '',
            'call_ringtone_silent': _callRingtoneSilent,
          },
        },
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Settings saved')),
        );
      }
    } catch (e) {
      debugPrint('Error saving conversation settings: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
  }

  Future<void> _playPreview(String? asset) async {
    if (asset == null || asset.isEmpty) {
      debugPrint('_playPreview: asset is null or empty');
      return;
    }
    
    debugPrint('_playPreview called with: $asset');
    
    // Skip audio preview on web (asset loading issues)
    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio preview not supported on web. Selection will be used on Android.')),
        );
      }
      return;
    }
    
    // Stop and dispose previous player if exists
    try {
      await _player?.stop();
      await _player?.dispose();
    } catch (_) {}
    
    // Create new player instance
    _player = AudioPlayer();
    
    try {
      // Configure audio context for Android
      await _player!.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          stayAwake: false,
        ),
      ));
    } catch (e) {
      debugPrint('Error setting audio context: $e');
    }
    
    await _player!.setReleaseMode(ReleaseMode.stop);
    await _player!.setVolume(1.0);
    
    try {
      // Validate asset exists before playing
      debugPrint('Validating asset with rootBundle.load: $asset');
      await rootBundle.load(asset);
      debugPrint('Asset validated successfully');
      
      // AssetSource needs path WITHOUT "assets/" prefix
      // Convert "assets/mp3 file/song.mp3" to "mp3 file/song.mp3"
      String assetPath = asset.replaceFirst('assets/', '');
      
      debugPrint('Calling _player!.play(AssetSource($assetPath))');
      await _player!.play(AssetSource(assetPath));
      debugPrint('Play command completed');
      
      if (!mounted) return;
      setState(() => _previewing = true);
      
      // Auto-stop after playback completes
      _player!.onPlayerComplete.first.then((_) {
        debugPrint('Playback completed');
        if (mounted) {
          setState(() => _previewing = false);
        }
      });
    } catch (e, stackTrace) {
      debugPrint('Preview error: $e');
      debugPrint('Stack trace: $stackTrace');
      
      if (!mounted) return;
      setState(() => _previewing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to play: $e')),
      );
    }
  }

  Future<void> _stopPreview() async {
    try {
      await _player?.stop();
    } catch (_) {}
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;
    
    if (mounted) {
      setState(() => _previewing = false);
    }
  }

  Widget _buildRingtoneSection({
    required String title,
    required bool silent,
    required ValueChanged<bool> onSilent,
    required String? selected,
    required ValueChanged<String?> onSelected,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                Row(
                  children: [
                    const Text('Silent'),
                    Switch(
                      value: silent,
                      onChanged: (v) {
                        onSilent(v);
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
            if (!silent)
              Column(
                children: [
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: (selected != null && selected.isNotEmpty && _mp3Assets.contains(selected))
                        ? selected
                        : null,
                    hint: const Text('Use default'),
                    items: _mp3Assets.map((p) {
                      final name = p.split('/').last;
                      return DropdownMenuItem(value: p, child: Text(name));
                    }).toList(),
                    onChanged: (v) {
                      onSelected(v);
                      setState(() {});
                      // Auto-play preview when selected
                      if (v != null && v.isNotEmpty) {
                        _playPreview(v);
                      }
                    },
                  ),
                  if (selected != null && selected.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: () async {
                            await _playPreview(selected);
                          },
                          icon: const Icon(Icons.play_arrow, size: 18),
                          label: const Text('Play'),
                        ),
                        const SizedBox(width: 12),
                        if (_previewing)
                          OutlinedButton.icon(
                            onPressed: () async {
                              await _stopPreview();
                            },
                            icon: const Icon(Icons.stop, size: 18),
                            label: const Text('Stop'),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.otherUserName} Settings'),
        actions: [
          TextButton(
            onPressed: () async {
              await _stopPreview();
              await _save();
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () async {
              await _stopPreview();
              await _load();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Changes discarded')),
                );
              }
            },
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const Padding(
                  padding: EdgeInsets.all(8.0),
                  child: Text(
                    'Customize notification sounds for this conversation. Changes only affect notifications and calls from this user.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                _buildRingtoneSection(
                  title: 'Message Notification',
                  silent: _notificationSilent,
                  onSilent: (v) => _notificationSilent = v,
                  selected: _notificationSound,
                  onSelected: (v) => _notificationSound = v,
                ),
                _buildRingtoneSection(
                  title: 'Call Ringtone',
                  silent: _callRingtoneSilent,
                  onSilent: (v) => _callRingtoneSilent = v,
                  selected: _callRingtone,
                  onSelected: (v) => _callRingtone = v,
                ),
              ],
            ),
    );
  }
}
