import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'supabase.dart' as sb;

// Optional: bring in Firestore if you want to flush Firestore-related actions here
// import 'package:cloud_firestore/cloud_firestore.dart';

/// Keys used for Workmanager and storage
class BackgroundKeys {
  static const periodicFlushTask = 'periodic_flush_task';
  static const oneOffFlushTask = 'one_off_flush_task';
  static const pendingActionsKey = 'pending_actions_v1';
}

/// BackgroundTasks handles a tiny offline action queue and schedules background
/// flush jobs using Workmanager. Keep actions small JSON maps so they can be
/// serialized and retried safely.
class BackgroundTasks {
  static bool _initialized = false;

  /// Call at startup once (Android only). Safe to call multiple times.
  static Future<void> initialize() async {
    if (_initialized) return;
    if (kIsWeb) return; // Workmanager doesn't apply to web
    try {
      await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
      // Try to schedule a 15-min periodic flush (Android minimum interval)
      await Workmanager().registerPeriodicTask(
        BackgroundKeys.periodicFlushTask,
        BackgroundKeys.periodicFlushTask,
        frequency: const Duration(minutes: 15),
        initialDelay: const Duration(minutes: 5),
  constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 5),
      );
    } catch (_) {
      // Ignore; device/manufacturer may restrict background tasks
    }
    _initialized = true;
  }

  /// Add a small action to local queue to be flushed later when online.
  /// Example action: {"type":"like","postId":"...","reaction":"like"}
  static Future<void> enqueueAction(Map<String, dynamic> action) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(BackgroundKeys.pendingActionsKey) ?? <String>[];
    list.add(jsonEncode(action));
    await prefs.setStringList(BackgroundKeys.pendingActionsKey, list);
  }

  /// Flush queued actions if connected.
  static Future<void> flushPending() async {
    final conn = await Connectivity().checkConnectivity();
    if (conn == ConnectivityResult.none) return;

    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(BackgroundKeys.pendingActionsKey) ?? <String>[];
    if (list.isEmpty) return;

    final remaining = <String>[];
    for (final item in list) {
      try {
        final map = jsonDecode(item) as Map<String, dynamic>;
        final type = map['type'] as String?;
        // TODO: Implement concrete handlers. For now, we simply drop unknowns.
        final handled = await _handleAction(type, map);
        if (!handled) {
          // keep for retry later
          remaining.add(item);
        }
      } catch (_) {
        // Corrupt item; drop it
      }
    }

    await prefs.setStringList(BackgroundKeys.pendingActionsKey, remaining);
  }
}

/// Background entry point invoked by Workmanager on a background isolate.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      // Ensure Firebase is available if your flush implementation needs it
      try {
        await Firebase.initializeApp();
        await sb.initializeSupabase();
      } catch (_) {}
      await BackgroundTasks.flushPending();
      return Future.value(true);
    } catch (_) {
      return Future.value(false);
    }
  });
}

/// Handle a single queued action. Returns true if processed, false if should retry later.
Future<bool> _handleAction(String? type, Map<String, dynamic> map) async {
  switch (type) {
    case 'upload_message_image':
    case 'upload_message_video':
    case 'upload_message_audio':
      return _handleQueuedMediaUpload(type!, map);
    default:
      return false;
  }
}

Future<bool> _handleQueuedMediaUpload(String type, Map<String, dynamic> map) async {
  try {
    final user = firebase_auth.FirebaseAuth.instance.currentUser;
    if (user == null) return false; // Retry when user signed in
    final conversationId = map['conversationId'] as String?;
    final messageId = map['messageId'] as String?;
    final localPath = map['localPath'] as String?;
    if (conversationId == null || conversationId.isEmpty || messageId == null || messageId.isEmpty || localPath == null || localPath.isEmpty) {
      return true; // drop invalid
    }

    // Upload to Supabase
    final file = File(localPath);
    String url;
    if (type == 'upload_message_image') {
      url = await sb.uploadMessageImage(file);
    } else if (type == 'upload_message_video') {
      url = await sb.uploadMessageVideo(file);
    } else {
      url = await sb.uploadMessageAudio(file);
    }

    // Update the placeholder message with the URL
    final msgRef = FirebaseFirestore.instance
        .collection('conversations')
        .doc(conversationId)
        .collection('messages')
        .doc(messageId);

    await msgRef.update(<String, dynamic>{
      'file_url': url,
      'uploading': false,
    });

    // Bump conversation last_message/last_updated
    final lastUpdated = DateTime.now().millisecondsSinceEpoch;
  String lastMessageText = '[File]';
  if (type == 'upload_message_image') {
    lastMessageText = '[Image]';
  } else if (type == 'upload_message_video') lastMessageText = '[Video]';
  else if (type == 'upload_message_audio') lastMessageText = '[Voice]';
    await FirebaseFirestore.instance.collection('conversations').doc(conversationId).update({
      'last_message': lastMessageText,
      'last_updated': lastUpdated,
      'last_read.${user.uid}': lastUpdated,
    });

    return true;
  } catch (_) {
    return false; // retry later
  }
}
