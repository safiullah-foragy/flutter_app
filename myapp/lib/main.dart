import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'agora_call_page.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'firebase_options.dart';
import 'login.dart';
// import 'homepage.dart'; // now hosted inside HomeAndFeedPage
import 'home_and_feed.dart';
import 'supabase.dart' as sb;
import 'messages.dart';
import 'fcm_web.dart';
import 'theme_controller.dart';
import 'background_tasks.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'connectivity_service.dart';
import 'notification_service.dart';

import 'dart:async';
import 'package:flutter/services.dart';
// Self-check overlay removed per request

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // Capture uncaught errors to avoid silent exits on web
    FlutterError.onError = (FlutterErrorDetails details) {
      // Print and keep default behavior
      // ignore: avoid_print
      print('FlutterError: ' + details.exceptionAsString());
      FlutterError.presentError(details);
    };

    // Initialize Firebase
    // ignore: avoid_print
    print('main: Initializing Firebase');
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    // ignore: avoid_print
    print('main: Firebase initialized');

    // App Check: activate providers
    // - In development, we use Debug providers so Firestore/Functions work even when enforcement is ON.
    // - For production, switch to Play Integrity (Android) and DeviceCheck/App Attest (Apple), and configure in Firebase Console.
    try {
      await FirebaseAppCheck.instance.activate(
        androidProvider: AndroidProvider.debug,
        appleProvider: AppleProvider.debug,
      );
      // Print a fresh debug token once to help register it in Firebase Console > App Check > Debug tokens
      try {
        final token = await FirebaseAppCheck.instance.getToken(true);
        // ignore: avoid_print
        print('AppCheck debug token (register this in Firebase Console if enforcement is enabled): ' + (token ?? 'null'));
      } catch (e) {
        // ignore: avoid_print
        print('AppCheck getToken error: ' + e.toString());
      }
    } catch (e) {
      // ignore: avoid_print
      print('AppCheck activation error: ' + e.toString());
    }

    // Ensure auth persistence across app restarts (especially for Web)
    if (kIsWeb) {
      try {
        await firebase_auth.FirebaseAuth.instance.setPersistence(firebase_auth.Persistence.LOCAL);
      } catch (_) {
        // ignore
      }
    }

    // Ensure Firestore disk persistence is enabled app-wide for offline cache.
    // On some web environments (incognito, blocked storage), enabling persistence can throw.
    try {
      FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true);
    } catch (_) {
      // Fallback: disable persistence if not supported to prevent startup crash/blank page
      try {
        FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: false);
      } catch (_) {}
    }

    // Initialize Supabase
    await sb.initializeSupabase();
    // ignore: avoid_print
    print('main: Supabase initialized');

    // Push notifications setup
    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      // Initialize notification service
      await NotificationService.instance.initialize();
      // Save FCM token ASAP if user is already signed in
      try {
        final u = firebase_auth.FirebaseAuth.instance.currentUser;
        final t = await FirebaseMessaging.instance.getToken();
        if (u != null && t != null) {
          await FirebaseFirestore.instance.collection('users').doc(u.uid).set({
            'fcmTokens': FieldValue.arrayUnion([t])
          }, SetOptions(merge: true));
        }
      } catch (_) {}
      await _setupPushNotifications();
    }

  // Load persisted theme before starting UI
  await ThemeController.instance.init();

  // Start the app UI ASAP
    // ignore: avoid_print
    print('main: calling runApp');
    // Initialize background tasks (Android): periodic flush of pending actions
    await BackgroundTasks.initialize();
    // Start connectivity watcher (toggles Firestore network and flushes queues)
    await ConnectivityService.instance.initialize();
    runApp(const MyApp());

    // Web: request permission and get token with VAPID key (deferred; don't block startup)
    if (kIsWeb) {
      unawaited(Future(() async {
        try {
          await FirebaseMessaging.instance.requestPermission();
        } catch (_) {}
        if (FcmWebConfig.vapidKey.isNotEmpty) {
          try {
            final token = await FirebaseMessaging.instance.getToken(vapidKey: FcmWebConfig.vapidKey);
            final u = firebase_auth.FirebaseAuth.instance.currentUser;
            if (token != null && u != null) {
              await FirebaseFirestore.instance.collection('users').doc(u.uid).set({
                'fcmTokens': FieldValue.arrayUnion([token])
              }, SetOptions(merge: true));
            }
          } catch (_) {}
        }
      }));
    }
  }, (e, st) {
    // ignore: avoid_print
    print('Uncaught zone error: $e\n$st');
  });
}

// Global instances
final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Ensure Firebase is initialized in background isolate
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Let the OS show notification if the payload contains `notification`.
  // If you plan to send data-only messages and want to surface notifications
  // yourself, consider using a dedicated background notifications flow.
}

Future<void> _setupPushNotifications() async {
  // Request permissions (Android 13+ and iOS)
  await FirebaseMessaging.instance.requestPermission();
  // On Android 13+, explicitly request notifications permission via local notifications plugin API
  try {
    await _flnp
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  } catch (_) {}

  // Android local notifications init
  const AndroidInitializationSettings androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initSettings = InitializationSettings(android: androidInit);
  await _flnp.initialize(initSettings,
      onDidReceiveNotificationResponse: (resp) {
    final payload = resp.payload;
    if (payload != null && payload.isNotEmpty) {
      _onNotificationTap(payload);
    }
  });

  // Create a default channel
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'messages',
    'Messages',
    description: 'Message notifications',
    importance: Importance.high,
  );
  await _flnp.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);

  // Foreground messages → show local notification with custom ringtone
  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    final n = message.notification;
    final data = message.data;
    if (n != null) {
      final convId = data['conversationId'] ?? '';
      final otherId = data['otherUserId'] ?? '';
      final type = data['type'] ?? 'message';
      
      if (type == 'call') {
        // Incoming call - show call notification with ringtone
        final channelName = data['channel'] ?? '';
        final isVideo = data['video'] == 'true';
        final sessionId = data['sessionId'] ?? '';
        final callerName = n.title ?? 'Unknown';
        
        await NotificationService.instance.showCallNotification(
          conversationId: convId,
          otherUserId: otherId,
          callerName: callerName,
          channelName: channelName,
          isVideo: isVideo,
          sessionId: sessionId,
        );
      } else {
        // Regular message - show message notification
        await NotificationService.instance.showMessageNotification(
          conversationId: convId,
          otherUserId: otherId,
          title: n.title ?? 'New message',
          body: n.body ?? '',
        );
      }
    }
  });

  // Taps: app in background
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    final convId = message.data['conversationId'];
    final otherId = message.data['otherUserId'] ?? '';
    if (convId != null) {
      _navigateToConversation(convId, otherId);
      _clearBadgeNative();
    }
  });

  // Taps: app terminated
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    final convId = initialMessage.data['conversationId'];
    final otherId = initialMessage.data['otherUserId'] ?? '';
    if (convId != null) {
      // Delay until app is built
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _navigateToConversation(convId, otherId);
        _clearBadgeNative();
      });
    }
  }
}

void _onNotificationTap(String payload) {
  if (payload.isEmpty) return;
  // Parse 'convId=...&otherId=...'
  try {
    final m = Uri.splitQueryString(payload);
    final convId = m['convId'] ?? '';
    final otherId = m['otherId'] ?? '';
    if (convId.isNotEmpty) {
      _navigateToConversation(convId, otherId);
      _clearBadgeNative();
    }
  } catch (_) {
    // Fallback: treat payload as conversationId only
    _navigateToConversation(payload, '');
  }
}

void _navigateToConversation(String conversationId, String otherUserId) {
  final ctx = _MyAppNavigator.navigatorKey.currentContext;
  if (ctx == null) return;
  Future<void> doNav(String resolvedOther) async {
    Navigator.of(ctx).restorablePush(
      ChatPage.restorableRoute,
      arguments: {
        'conversationId': conversationId,
        'otherUserId': resolvedOther,
      },
    );
  }

  // Ensure user is signed-in before navigating (especially on cold-start from notif)
  final user = firebase_auth.FirebaseAuth.instance.currentUser;
  if (user == null) {
    firebase_auth.FirebaseAuth.instance.authStateChanges().firstWhere((u) => u != null).then((_) {
      _navigateToConversation(conversationId, otherUserId);
    });
    return;
  }

  if (otherUserId.isEmpty) {
    // Try to resolve other user id from Firestore before navigating
    FirebaseFirestore.instance.collection('conversations').doc(conversationId).get().then((doc) {
      final me = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
      String resolved = otherUserId;
      if (doc.exists) {
        final data = doc.data();
        final parts = List<String>.from(data?['participants'] ?? <String>[]);
        if (me != null) {
          resolved = parts.firstWhere((p) => p != me, orElse: () => otherUserId);
        }
      }
      doNav(resolved.isNotEmpty ? resolved : otherUserId);
    }).catchError((_) {
      doNav(otherUserId);
    });
  } else {
    doNav(otherUserId);
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('MyApp.build');
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'MyApp',
          restorationScopeId: 'app',
          themeMode: ThemeController.instance.mode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: ThemeController.instance.seedColor, brightness: Brightness.light),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: ThemeController.instance.seedColor, brightness: Brightness.dark),
            useMaterial3: true,
          ),
          navigatorKey: _MyAppNavigator.navigatorKey,
          builder: (context, child) {
            // Global unread message bubble overlay removed per request
            return Stack(
              children: [
                if (child != null) child,
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: OfflineBanner(),
                ),
              ],
            );
          },
          home: const MessagingInitializer(child: AuthGate()),
        );
      },
    );
  }
}

class _MyAppNavigator {
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
}

class MessagingInitializer extends StatefulWidget {
  final Widget child;
  const MessagingInitializer({super.key, required this.child});

  @override
  State<MessagingInitializer> createState() => _MessagingInitializerState();
}

class _MessagingInitializerState extends State<MessagingInitializer> with WidgetsBindingObserver {
  static const MethodChannel _navChannel = MethodChannel('com.example.myapp/navigation');
  static const MethodChannel _appChannel = MethodChannel('com.example.myapp/app');
  StreamSubscription<firebase_auth.User?>? _authSub;
  StreamSubscription<QuerySnapshot>? _callSessionSub;
  @override
  void initState() {
    super.initState();
    // Observe app lifecycle to start/stop Android background watcher
    WidgetsBinding.instance.addObserver(this);
    // On web, messaging may be disabled or service worker missing; wrap to avoid crashes
    _ensureFcmTokenSaved();
    try {
      FirebaseMessaging.instance.onTokenRefresh.listen((token) => _saveFcmToken(token));
    } catch (_) {}
    // Ensure token is saved as soon as user signs in
    _authSub = firebase_auth.FirebaseAuth.instance.authStateChanges().listen((u) async {
      final prefs = await SharedPreferences.getInstance();
      final lastUid = prefs.getString('last_topic_uid');
      if (u != null) {
        // Save token and subscribe to a per-user topic for robust delivery
        await _ensureFcmTokenSaved();
        final topic = 'user_' + u.uid;
        try { await FirebaseMessaging.instance.subscribeToTopic(topic); } catch (_) {}
        await prefs.setString('last_topic_uid', u.uid);
        _attachCallSessionListener(u.uid);
      } else {
        // On sign out, best-effort unsubscribe from previous topic
        if (lastUid != null && lastUid.isNotEmpty) {
          try { await FirebaseMessaging.instance.unsubscribeFromTopic('user_' + lastUid); } catch (_) {}
          await prefs.remove('last_topic_uid');
        }
        // Stop background watcher if running
        _stopMessageWatcher();
        _detachCallSessionListener();
      }
    });
    // Listen for navigation requests from Android native (notification taps)
    _navChannel.setMethodCallHandler((call) async {
      if (call.method == 'openConversation') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final convId = args['conversationId'] as String?;
        if (convId != null && convId.isNotEmpty) {
          _navigateToConversation(convId, '');
          _clearBadgeNative();
        }
      } else if (call.method == 'openCall') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final channel = args['channel'] as String?;
        final callerId = args['callerId'] as String?;
        final video = (args['video'] as bool?) ?? false;
        final sessionId = args['sessionId'] as String?;
        if (channel != null && channel.isNotEmpty && callerId != null && callerId.isNotEmpty) {
          try {
            // Try to find existing session id by querying call_sessions
            String? sess = sessionId;
            if (sess == null) {
              try {
                final snap = await FirebaseFirestore.instance
                    .collection('call_sessions')
                    .where('channel', isEqualTo: channel)
                    .where('caller_id', isEqualTo: callerId)
                    .limit(1)
                    .get();
                if (snap.docs.isNotEmpty) sess = snap.docs.first.id;
              } catch (_) {}
            }
            final convId = await _findConversationWith(callerId);
            _MyAppNavigator.navigatorKey.currentState?.push(
              CallPage.route(channelName: channel, video: video, conversationId: convId, remoteUserId: callerId, callSessionId: sess),
            );
          } catch (_) {}
        }
      }
    });
  }

  Future<void> _ensureFcmTokenSaved() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _saveFcmToken(token);
    } catch (_) {}
  }

  Future<void> _saveFcmToken(String token) async {
    final user = firebase_auth.FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'fcmTokens': FieldValue.arrayUnion([token]),
    }, SetOptions(merge: true));
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _detachCallSessionListener();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Start the native foreground service when app is backgrounded; stop when resumed
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!kIsWeb) {
      if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
        _startMessageWatcher();
      } else if (state == AppLifecycleState.resumed) {
        _stopMessageWatcher();
      }
    }
  }

  Future<void> _startMessageWatcher() async {
    try {
      await _appChannel.invokeMethod('startMessageWatcher');
    } catch (_) {}
  }

  Future<void> _stopMessageWatcher() async {
    try {
      await _appChannel.invokeMethod('stopMessageWatcher');
    } catch (_) {}
  }

  void _attachCallSessionListener(String uid) {
    _callSessionSub?.cancel();
    _callSessionSub = FirebaseFirestore.instance
        .collection('call_sessions')
        .where('callee_id', isEqualTo: uid)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snap) {
      if (snap.docs.isEmpty) return;
      for (final doc in snap.docs) {
        final data = doc.data();
        final channel = data['channel'] as String? ?? '';
        final callerId = data['caller_id'] as String? ?? '';
        final video = data['video'] == true;
        if (channel.isEmpty || callerId.isEmpty) continue;
        _showIncomingCallGlobal(doc.reference, callerId, channel, video);
      }
    });
  }

  void _detachCallSessionListener() {
    _callSessionSub?.cancel();
    _callSessionSub = null;
  }

  bool _showingGlobalCall = false;
  Future<void> _showIncomingCallGlobal(DocumentReference ref, String callerId, String channel, bool video) async {
    if (_showingGlobalCall || !mounted) return;
    _showingGlobalCall = true;
    
    // Find conversation to get custom ringtone
    final convId = await _findConversationWith(callerId);
    
    // Start playing ringtone
    String ringtonePath = NotificationService.defaultCallRingtone;
    if (convId != null) {
      try {
        final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
        if (uid != null) {
          final doc = await FirebaseFirestore.instance.collection('conversations').doc(convId).get();
          if (doc.exists) {
            final data = doc.data() ?? {};
            final settings = data['settings'] as Map<String, dynamic>? ?? {};
            final userSettings = settings[uid] as Map<String, dynamic>? ?? {};
            final isSilent = userSettings['call_ringtone_silent'] as bool? ?? false;
            final customPath = userSettings['call_ringtone'] as String?;
            
            if (!isSilent) {
              if (customPath != null && customPath.isNotEmpty) {
                ringtonePath = customPath;
              }
              debugPrint('Starting call ringtone: $ringtonePath');
              await NotificationService.instance.playCallRingtone(ringtonePath);
            }
          }
        }
      } catch (e) {
        debugPrint('Error loading ringtone settings: $e');
        // Play default ringtone on error
        await NotificationService.instance.playCallRingtone(ringtonePath);
      }
    } else {
      // No conversation found, play default
      debugPrint('No conversation found, playing default ringtone');
      await NotificationService.instance.playCallRingtone(ringtonePath);
    }
    
    // Load caller profile
    Map<String, dynamic>? user;
    try {
      final udoc = await FirebaseFirestore.instance.collection('users').doc(callerId).get();
      if (udoc.exists) user = udoc.data();
    } catch (_) {}
    final name = user?['name'] ?? callerId;
    final avatarUrl = user?['profile_image'];
    
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: Colors.black87,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 48,
                  backgroundColor: Colors.blueGrey,
                  backgroundImage: (avatarUrl is String && avatarUrl.isNotEmpty) ? NetworkImage(avatarUrl) : null,
                  child: (avatarUrl is String && avatarUrl.isNotEmpty) ? null : Text(name[0].toUpperCase(), style: const TextStyle(fontSize: 32, color: Colors.white)),
                ),
                const SizedBox(height: 16),
                Text('${video ? 'Video' : 'Audio'} call from', style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Text(name, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                      onPressed: () async {
                        // Stop ringtone
                        await NotificationService.instance.stopCallRingtone();
                        try { await ref.update({'status': 'rejected', 'ended_at': DateTime.now().millisecondsSinceEpoch}); } catch (_) {}
                        Navigator.pop(c);
                      },
                      icon: const Icon(Icons.call_end),
                      label: const Text('Decline'),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                      onPressed: () async {
                        // Stop ringtone
                        await NotificationService.instance.stopCallRingtone();
                        try { await ref.update({'status': 'accepted', 'accepted_at': DateTime.now().millisecondsSinceEpoch}); } catch (_) {}
                        Navigator.pop(c);
                        // Start call page directly
                        _MyAppNavigator.navigatorKey.currentState?.push(CallPage.route(channelName: channel, video: video, conversationId: convId, remoteUserId: callerId, callSessionId: ref.id));
                      },
                      icon: Icon(video ? Icons.videocam : Icons.call),
                      label: const Text('Accept'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    
    // Stop ringtone when dialog closes (in case user didn't press buttons)
    await NotificationService.instance.stopCallRingtone();
    _showingGlobalCall = false;
  }

  Future<String?> _findConversationWith(String otherId) async {
    final uid = firebase_auth.FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    try {
      final snap = await FirebaseFirestore.instance.collection('conversations').where('participants', arrayContains: uid).get();
      for (final d in snap.docs) {
        final parts = List<String>.from(d.data()['participants'] ?? []);
        if (parts.contains(otherId)) return d.id;
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  static bool _didHandleInitialLink = false;

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('AuthGate.build');
    return StreamBuilder<firebase_auth.User?>(
      stream: firebase_auth.FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // ignore: avoid_print
        print('AuthGate: connectionState=' + snapshot.connectionState.toString() + ', hasData=' + (snapshot.data != null).toString());
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snapshot.data;
        if (user != null) {
          // ignore: avoid_print
          print('AuthGate: user logged in');
          // User is signed in; keep them logged in until explicit sign out
          // Handle web deep link: #conv=conversationId
          if (kIsWeb && !_didHandleInitialLink) {
            _didHandleInitialLink = true;
            final frag = Uri.base.fragment; // e.g., conv=abc
            if (frag.contains('conv=')) {
              final convId = Uri.splitQueryString(frag)['conv'];
              if (convId != null && convId.isNotEmpty) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _navigateToConversation(convId, '');
                });
              }
            }
          }
          return const HomeAndFeedPage();
        }
        // ignore: avoid_print
        print('AuthGate: no user, showing LoginPage');
        // Not signed in
        return const LoginPage();
      },
    );
  }
}

Future<void> _clearBadgeNative() async {
  try {
    const MethodChannel('com.example.myapp/app').invokeMethod('clearBadge');
  } catch (_) {}
}