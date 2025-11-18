import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  List<String> _mp3Assets = [];
  String? _ringtoneCall;
  bool _ringtoneCallSilent = false;
  String? _ringtoneMessage;
  bool _ringtoneMessageSilent = false;
  bool _loading = true;
  AudioPlayer? _player;
  bool _previewing = false;
  @override
  void dispose() {
    _stopPreview();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Load asset manifest and filter mp3s in Assets/mp3 file/
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifest = json.decode(manifestContent);
      final keys = manifest.keys.where((k) => k.toLowerCase().startsWith('assets/mp3 file/') && k.toLowerCase().endsWith('.mp3')).toList();
      keys.sort();
      _mp3Assets = keys;
    } catch (_) {
      _mp3Assets = [];
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      _ringtoneCall = prefs.getString('ringtone_call');
      _ringtoneCallSilent = prefs.getBool('ringtone_call_silent') ?? false;
      _ringtoneMessage = prefs.getString('ringtone_message');
      _ringtoneMessageSilent = prefs.getBool('ringtone_message_silent') ?? false;
      // Defaults if not set and files exist
      final defCall = 'assets/mp3 file/lovely-Alarm.mp3';
      final defMsg = 'assets/mp3 file/Iphone-Notification.mp3';
      if ((_ringtoneCall == null || _ringtoneCall!.isEmpty) && _mp3Assets.contains(defCall)) {
        _ringtoneCall = defCall;
      }
      if ((_ringtoneMessage == null || _ringtoneMessage!.isEmpty) && _mp3Assets.contains(defMsg)) {
        _ringtoneMessage = defMsg;
      }
      // Do not auto-save; allow user to review and explicitly save
    } catch (_) {}
    
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ringtone_call', _ringtoneCall ?? '');
    await prefs.setBool('ringtone_call_silent', _ringtoneCallSilent);
    await prefs.setString('ringtone_message', _ringtoneMessage ?? '');
    await prefs.setBool('ringtone_message_silent', _ringtoneMessageSilent);

    // Mirror in Firestore user profile for cross-device, best-effort
    final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final data = {
        'ringtone_call': _ringtoneCall ?? '',
        'ringtone_call_silent': _ringtoneCallSilent,
        'ringtone_message': _ringtoneMessage ?? '',
        'ringtone_message_silent': _ringtoneMessageSilent,
      };
      try {
        await FirebaseFirestore.instance.collection('users').doc(uid).set(data, SetOptions(merge: true));
      } catch (_) {}
    }
  }

  Future<void> _playPreview(String? assetPath) async {
    if (assetPath == null || assetPath.isEmpty) return;
    // Skip audio preview on web (asset loading issues)
    if (kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio preview not supported on web. Selection will be used on Android.')),
        );
      }
      return;
    }
    try {
      await _player?.stop();
      await _player?.dispose();
    } catch (_) {}
    _player = AudioPlayer();
    try {
      await _player!.setAudioContext(AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.notification,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          stayAwake: false,
        ),
      ));
    } catch (_) {}
    await _player!.setReleaseMode(ReleaseMode.stop);
    await _player!.setVolume(1.0);
    try {
      // Validate asset exists before playing (skip validation on web)
      if (!kIsWeb) {
        await rootBundle.load(assetPath);
      }
      // Strip 'assets/' prefix for AssetSource
      String strippedPath = assetPath.replaceFirst('assets/', '');
      await _player!.play(AssetSource(strippedPath));
      
      if (!mounted) return;
      setState(() => _previewing = true);
      
      // Auto-stop after playback completes
      _player!.onPlayerComplete.first.then((_) {
        if (mounted) {
          setState(() => _previewing = false);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _previewing = false);
    }
  }

  Future<void> _stopPreview() async {
    try { await _player?.stop(); } catch (_) {}
    try { await _player?.dispose(); } catch (_) {}
    _player = null;
    
    if (mounted) {
      setState(() => _previewing = false);
    }
  }

  Widget _buildRingtoneSection({required String title, required bool silent, required ValueChanged<bool> onSilent, required String? selected, required ValueChanged<String?> onSelected, required Future<void> Function() onPreview}) {
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
                Row(children: [
                  const Text('Silent'),
                  Switch(value: silent, onChanged: (v) { 
                    onSilent(v); 
                    if (mounted) setState(() {}); 
                  }),
                ]),
              ],
            ),
            if (!silent)
              Column(
                children: [
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: (selected != null && selected.isNotEmpty && _mp3Assets.contains(selected)) ? selected : null,
                    hint: const Text('Select ringtone'),
                    items: _mp3Assets.map((p) {
                      final name = p.split('/').last;
                      return DropdownMenuItem(value: p, child: Text(name));
                    }).toList(),
                    onChanged: (v) { 
                      onSelected(v); 
                      if (mounted) setState(() {}); 
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: () async { await onPreview(); },
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Play'),
                      ),
                      const SizedBox(width: 12),
                      if (_previewing)
                        OutlinedButton.icon(
                          onPressed: () async { await _stopPreview(); },
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        ),
                    ],
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: () async {
              await _savePrefs();
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () async {
              await _stopPreview();
              await _load(); // revert unsaved changes
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Changes discarded')));
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
                _buildRingtoneSection(
                  title: 'Call Ringtone',
                  silent: _ringtoneCallSilent,
                  onSilent: (v) => _ringtoneCallSilent = v,
                  selected: _ringtoneCall,
                  onSelected: (v) => _ringtoneCall = v,
                  onPreview: () async {
                    if (_ringtoneCallSilent) return;
                    await _playPreview(_ringtoneCall);
                  },
                ),
                _buildRingtoneSection(
                  title: 'Message Ringtone',
                  silent: _ringtoneMessageSilent,
                  onSilent: (v) => _ringtoneMessageSilent = v,
                  selected: _ringtoneMessage,
                  onSelected: (v) => _ringtoneMessage = v,
                  onPreview: () async {
                    if (_ringtoneMessageSilent) return;
                    await _playPreview(_ringtoneMessage);
                  },
                ),
              ],
            ),
    );
  }
}
