import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'homepage.dart';
import 'newsfeed.dart';

/// A single entry page that hosts both the public Newsfeed and the user's Profile (HomePage)
/// in the same space with a simple bottom navigation: Home (feed) and Profile (avatar icon).
class HomeAndFeedPage extends StatefulWidget {
  const HomeAndFeedPage({super.key});

  @override
  State<HomeAndFeedPage> createState() => _HomeAndFeedPageState();
}

class _HomeAndFeedPageState extends State<HomeAndFeedPage> with RestorationMixin {
  final RestorableInt _currentIndex = RestorableInt(0);

  @override
  String? get restorationId => 'home_and_feed';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_currentIndex, 'tab_index');
  }

  @override
  Widget build(BuildContext context) {
    final user = firebase_auth.FirebaseAuth.instance.currentUser;
    // Keep the children mounted using IndexedStack to preserve their state
    final pages = <Widget>[
      const NewsfeedPage(),
      const HomePage(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex.value, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex.value,
        onTap: (i) => setState(() => _currentIndex.value = i),
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: user?.photoURL != null
                ? CircleAvatar(radius: 10, backgroundImage: NetworkImage(user!.photoURL!))
                : const Icon(Icons.person_outline),
            activeIcon: user?.photoURL != null
                ? CircleAvatar(radius: 10, backgroundImage: NetworkImage(user!.photoURL!))
                : const Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
