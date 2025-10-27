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

class _HomeAndFeedPageState extends State<HomeAndFeedPage> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final user = firebase_auth.FirebaseAuth.instance.currentUser;
    // Keep the children mounted using IndexedStack to preserve their state
    final pages = <Widget>[
      const NewsfeedPage(),
      const HomePage(),
    ];

    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
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
