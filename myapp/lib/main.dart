import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';
import 'login.dart';
import 'homepage.dart';
import 'supabase.dart' as sb;
import 'messages.dart';
import 'fcm_web.dart';
import 'new_message_overlay.dart';

import 'dart:async';
import 'package:flutter/services.dart';

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
      await _setupPushNotifications();
    }

    // Start the app UI ASAP
    // ignore: avoid_print
    print('main: calling runApp');
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

  // Foreground messages → show local notification
  FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
    final n = message.notification;
    final data = message.data;
    if (n != null) {
      await _flnp.show(
        n.hashCode,
        n.title ?? 'New message',
        n.body ?? '',
        const NotificationDetails(
          android: AndroidNotificationDetails('messages', 'Messages', importance: Importance.high, priority: Priority.high),
        ),
        payload: data['conversationId'] ?? '',
      );
    }
  });

  // Taps: app in background
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    final convId = message.data['conversationId'];
    final otherId = message.data['otherUserId'] ?? '';
    if (convId != null) {
      _navigateToConversation(convId, otherId);
    }
  });

  // Taps: app terminated
  final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    final convId = initialMessage.data['conversationId'];
    final otherId = initialMessage.data['otherUserId'] ?? '';
    if (convId != null) {
      // Delay until app is built
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigateToConversation(convId, otherId));
    }
  }
}

void _onNotificationTap(String payload) {
  _navigateToConversation(payload, '');
}

void _navigateToConversation(String conversationId, String otherUserId) {
  final ctx = _MyAppNavigator.navigatorKey.currentContext;
  if (ctx != null) {
    Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => ChatPage(conversationId: conversationId, otherUserId: otherUserId),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('MyApp.build');
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MyApp',
      theme: ThemeData(primarySwatch: Colors.blue),
      navigatorKey: _MyAppNavigator.navigatorKey,
      builder: (context, child) {
        // Place a global unread message bubble overlay on top of all routes
        return Stack(
          children: [
            if (child != null) child,
            const GlobalNewMessageBubble(),
          ],
        );
      },
  home: const MessagingInitializer(child: AuthGate()),
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

class _MessagingInitializerState extends State<MessagingInitializer> {
  static const MethodChannel _navChannel = MethodChannel('com.example.myapp/navigation');
  @override
  void initState() {
    super.initState();
    // On web, messaging may be disabled or service worker missing; wrap to avoid crashes
    _ensureFcmTokenSaved();
    try {
      FirebaseMessaging.instance.onTokenRefresh.listen((token) => _saveFcmToken(token));
    } catch (_) {}
    // Listen for navigation requests from Android native (notification taps)
    _navChannel.setMethodCallHandler((call) async {
      if (call.method == 'openConversation') {
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final convId = args['conversationId'] as String?;
        if (convId != null && convId.isNotEmpty) {
          _navigateToConversation(convId, '');
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
          return const HomePage();
        }
        // ignore: avoid_print
        print('AuthGate: no user, showing LoginPage');
        // Not signed in
        return const LoginPage();
      },
    );
  }
}