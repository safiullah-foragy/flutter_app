import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._();
  NotificationService._();

  final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();
  AudioPlayer? _ringtonePlayer;

  // Real-time Firestore notification subscription
  StreamSubscription<QuerySnapshot>? _notificationSubscription;
  final Set<String> _seenNotificationIds = {};
  bool _initialLoadDone = false;

  // Default ringtones
  static const String defaultCallRingtone = 'assets/mp3 file/Lovely-Alarm.mp3';
  static const String defaultMessageSound = 'assets/mp3 file/Iphone-Notification.mp3';

  Future<void> initialize() async {
    if (kIsWeb) return;

    const AndroidInitializationSettings androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings = InitializationSettings(android: androidInit);

    await _flnp.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        debugPrint('Notification tapped: ${response.payload}');
      },
    );

    // Create notification channels
    await _createNotificationChannels();
  }

  Future<void> _createNotificationChannels() async {
    // General notifications channel (likes, comments, system alerts, jobs)
    const AndroidNotificationChannel generalChannel = AndroidNotificationChannel(
      'general_notifications',
      'Activity Notifications',
      description: 'Likes, comments, reactions, and connection alerts',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('notification'),
      enableVibration: true,
      showBadge: true,
    );

    // Message notification channel (high importance, with sound)
    const AndroidNotificationChannel messageChannel = AndroidNotificationChannel(
      'messages',
      'Messages',
      description: 'Message notifications',
      importance: Importance.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('notification'),
      enableVibration: true,
    );

    // Call notification channel (max importance, full screen intent, with sound)
    const AndroidNotificationChannel callChannel = AndroidNotificationChannel(
      'calls',
      'Calls',
      description: 'Incoming call notifications',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('ringtone'),
      enableVibration: true,
    );

    final androidPlugin = _flnp.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(generalChannel);
      await androidPlugin.createNotificationChannel(messageChannel);
      await androidPlugin.createNotificationChannel(callChannel);
    }
  }

  /// Request notification permissions across Android & iOS
  Future<bool> requestNotificationPermissions() async {
    bool granted = false;
    try {
      // 1. Firebase Messaging permission
      final fcmSettings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
      if (fcmSettings.authorizationStatus == AuthorizationStatus.authorized) {
        granted = true;
      }

      // 2. Android 13+ (API 33+) native permission
      if (!kIsWeb) {
        final androidPlugin = _flnp.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin != null) {
          final androidGranted = await androidPlugin.requestNotificationsPermission();
          if (androidGranted != null) {
            granted = androidGranted;
          }
        }
      }
    } catch (e) {
      debugPrint('Error requesting notification permissions: $e');
    }
    return granted;
  }

  /// Check if notifications are enabled
  Future<bool> checkNotificationPermission() async {
    try {
      if (!kIsWeb) {
        final androidPlugin = _flnp.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidPlugin != null) {
          final areEnabled = await androidPlugin.areNotificationsEnabled();
          return areEnabled ?? true;
        }
      }
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized;
    } catch (_) {
      return true;
    }
  }

  /// Start real-time Firestore listener for user's notifications to trigger direct Android status bar alerts
  void startRealtimeNotificationListener(String currentUserId) {
    if (currentUserId.isEmpty) return;

    _notificationSubscription?.cancel();
    _initialLoadDone = false;
    _seenNotificationIds.clear();

    debugPrint('🔔 Starting real-time notification listener for user: $currentUserId');

    // Query simple without composite orderBy to ensure 100% reliable real-time updates without index requirement
    _notificationSubscription = FirebaseFirestore.instance
        .collection('notifications')
        .where('to', isEqualTo: currentUserId)
        .snapshots()
        .listen(
      (snapshot) {
        // Populate existing unread ids on initial snapshot so we don't spam old notifications
        if (!_initialLoadDone) {
          for (final doc in snapshot.docs) {
            _seenNotificationIds.add(doc.id);
          }
          _initialLoadDone = true;
          debugPrint('🔔 Notification listener initialized with ${_seenNotificationIds.length} existing items');
          return;
        }

        for (final change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added || change.type == DocumentChangeType.modified) {
            final data = change.doc.data();
            if (data == null) continue;

            final docId = change.doc.id;
            final isRead = (data['read'] ?? false) as bool;

            // Only notify if unread and not already alerted in this session
            if (!isRead && !_seenNotificationIds.contains(docId)) {
              _seenNotificationIds.add(docId);

              final type = (data['type'] ?? '') as String;
              final reaction = (data['reaction'] ?? '') as String;
              final fromName = (data['fromName'] ?? 'Someone') as String;
              final customText = (data['text'] ?? '') as String;
              final commentText = (data['commentText'] ?? '') as String;

              String title = 'Connectify';
              String body = 'You have a new notification';

              if (type == 'like') {
                String reactionEmoji = '❤️';
                if (reaction.toLowerCase() == 'love') reactionEmoji = '❤️';
                if (reaction.toLowerCase() == 'like') reactionEmoji = '👍';
                if (reaction.toLowerCase() == 'care') reactionEmoji = '🥰';
                if (reaction.toLowerCase() == 'wow') reactionEmoji = '😮';
                if (reaction.toLowerCase() == 'sad') reactionEmoji = '😢';
                if (reaction.toLowerCase() == 'angry') reactionEmoji = '😡';

                title = '$reactionEmoji New Reaction';
                body = '$fromName reacted $reactionEmoji to your post';
              } else if (type == 'comment') {
                title = '💬 New Comment';
                body = commentText.isNotEmpty
                    ? '$fromName: "$commentText"'
                    : '$fromName commented on your post';
              } else if (type == 'connect' || type == 'friend') {
                title = '🤝 Connection Request';
                body = '$fromName sent you a connection request';
              } else if (type == 'job') {
                title = '💼 Job Opportunity';
                body = customText.isNotEmpty ? customText : 'A new job was posted';
              } else if (customText.isNotEmpty) {
                title = 'Connectify Alert';
                body = customText;
              }

              debugPrint('📲 Showing Android status bar alert: $title - $body');

              // Show Android Status Bar Notification
              showGeneralNotification(
                id: docId.hashCode,
                title: title,
                body: body,
                payload: 'notification_id=$docId&type=$type',
                type: type,
              );

              // Play gentle notification sound
              playMessageSound();
            }
          }
        }
      },
      onError: (e) {
        debugPrint('Error in real-time notification listener: $e');
      },
    );
  }

  /// Stop real-time notification listener
  void stopRealtimeNotificationListener() {
    _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _initialLoadDone = false;
    _seenNotificationIds.clear();
  }

  /// Show general notification (likes, comments, system) with sound & vibration
  Future<void> showGeneralNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
    String? type,
  }) async {
    if (kIsWeb) return;

    await _flnp.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'general_notifications',
          'Activity Notifications',
          channelDescription: 'Likes, comments, reactions, and connection alerts',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('notification'),
          enableVibration: true,
          styleInformation: BigTextStyleInformation(''),
          fullScreenIntent: false,
        ),
      ),
      payload: payload,
    );
  }

  /// Show message notification with constant ringtone
  Future<void> showMessageNotification({
    required String conversationId,
    required String otherUserId,
    required String title,
    required String body,
  }) async {
    if (kIsWeb) return;

    final payload = 'convId=$conversationId&otherId=$otherUserId';
    await _flnp.show(
      conversationId.hashCode,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          channelDescription: 'Message notifications',
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('notification'),
          enableVibration: true,
        ),
      ),
      payload: payload,
    );
  }

  /// Show incoming call notification with constant ringtone
  Future<void> showCallNotification({
    required String conversationId,
    required String otherUserId,
    required String callerName,
    required String channelName,
    required bool isVideo,
    required String sessionId,
  }) async {
    if (kIsWeb) return;

    await _playCallRingtone(defaultCallRingtone);

    final payload = 'call&convId=$conversationId&otherId=$otherUserId&channel=$channelName&video=$isVideo&sessionId=$sessionId';

    await _flnp.show(
      sessionId.hashCode,
      '${isVideo ? 'Video' : 'Audio'} Call',
      'Incoming call from $callerName',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Calls',
          channelDescription: 'Incoming call notifications',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          sound: RawResourceAndroidNotificationSound('ringtone'),
          enableVibration: true,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
          ongoing: true,
          autoCancel: false,
          actions: [
            AndroidNotificationAction('decline', '🔴 Decline', showsUserInterface: false),
            AndroidNotificationAction('accept', '🟢 Receive', showsUserInterface: true),
          ],
        ),
      ),
      payload: payload,
    );
  }

  /// Play call ringtone (looping)
  Future<void> _playCallRingtone(String assetPath) async {
    try {
      await stopCallRingtone();
      _ringtonePlayer = AudioPlayer();

      if (!kIsWeb) {
        await _ringtonePlayer!.setAudioContext(AudioContext(
          android: const AudioContextAndroid(
            isSpeakerphoneOn: true,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.notificationRingtone,
            audioFocus: AndroidAudioFocus.gain,
          ),
        ));
      }

      await _ringtonePlayer!.setReleaseMode(ReleaseMode.loop);
      await _ringtonePlayer!.setVolume(1.0);

      String strippedPath = assetPath.replaceFirst('assets/', '');
      final source = AssetSource(strippedPath);
      await _ringtonePlayer!.play(source);
    } catch (e) {
      debugPrint('Error playing call ringtone: $e');
      try {
        await stopCallRingtone();
      } catch (_) {}
    }
  }

  /// Play message notification sound once
  Future<void> playMessageSound() async {
    try {
      final player = AudioPlayer();
      await player.setVolume(0.6);
      await player.play(AssetSource('mp3 file/Iphone-Notification.mp3'));
      player.onPlayerComplete.first.then((_) {
        player.dispose();
      });
    } catch (e) {
      debugPrint('Error playing notification sound: $e');
    }
  }

  AudioPlayer? _outgoingRingtonePlayer;

  Future<void> playCallRingtone(String assetPath) async {
    await _playCallRingtone(assetPath);
  }

  Future<void> stopCallRingtone() async {
    try {
      await _ringtonePlayer?.stop();
      await _ringtonePlayer?.dispose();
      _ringtonePlayer = null;
    } catch (e) {
      debugPrint('Error stopping ringtone: $e');
    }
  }

  Future<void> playOutgoingRingtone({String assetPath = ''}) async {
    // Do not play incoming ringtone on caller side
  }

  Future<void> stopOutgoingRingtone() async {
    try {
      await _outgoingRingtonePlayer?.stop();
      await _outgoingRingtonePlayer?.dispose();
      _outgoingRingtonePlayer = null;
    } catch (_) {}
  }

  Future<void> cancelNotification(int id) async {
    await _flnp.cancel(id);
  }

  Future<void> cancelAllNotifications() async {
    await _flnp.cancelAll();
    await stopCallRingtone();
    await stopOutgoingRingtone();
  }
}
