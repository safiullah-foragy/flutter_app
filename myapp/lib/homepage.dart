import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'login.dart';
import 'newsfeed.dart';
import 'ProfileImagesPage.dart';
import 'package:intl/intl.dart';
import 'supabase.dart' as sb;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ImagePicker _imagePicker = ImagePicker();
  Map<String, dynamic>? userData;
  bool isLoading = true;
  bool isUploading = false;
  final Map<String, TextEditingController> _controllers = {};
  
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _fetchUserData();
    _updateLastLogin();
    
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    
    _slideAnimation = Tween<Offset>(
      begin: const Offset(-1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));
    
    Future.delayed(const Duration(milliseconds: 500), () {
      _animationController.forward();
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    _controllers.forEach((key, controller) {
      controller.dispose();
    });
    super.dispose();
  }

  Future<void> _updateLastLogin() async {
    final User? user = _auth.currentUser;
    if (user != null) {
      await _firestore.collection('users').doc(user.uid).update({
        'last_login': DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
      });
    }
  }

  Future<void> _fetchUserData() async {
    try {
      final User? user = _auth.currentUser;
      if (user != null) {
        DocumentSnapshot userDoc = 
            await _firestore.collection('users').doc(user.uid).get();
            
        if (userDoc.exists) {
          setState(() {
            userData = userDoc.data() as Map<String, dynamic>;
            
            _controllers['name'] = TextEditingController(text: userData?['name'] ?? '');
            _controllers['dob'] = TextEditingController(text: userData?['dob'] ?? '');
            _controllers['current_job'] = TextEditingController(text: userData?['current_job'] ?? '');
            _controllers['experience'] = TextEditingController(text: userData?['experience'] ?? '');
            _controllers['session'] = TextEditingController(text: userData?['session'] ?? '');
            
            isLoading = false;
          });
        }
      }
    } catch (e) {
      print('Error fetching user data: $e');
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _updateField(String field, dynamic value) async {
    try {
      final User? user = _auth.currentUser;
      if (user != null) {
        await _firestore.collection('users').doc(user.uid).update({
          field: value,
        });
        
        setState(() {
          userData?[field] = value;
        });
        
        Fluttertoast.showToast(msg: '${_getFieldDisplayName(field)} updated successfully');
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error updating ${_getFieldDisplayName(field)}: $e');
    }
  }

  Future<void> _uploadProfileImage() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 800,
        maxHeight: 800,
      );
      
      if (pickedFile != null) {
        setState(() {
          isUploading = true;
        });
        
        final User? user = _auth.currentUser;
        if (user != null) {
          File imageFile = File(pickedFile.path);
          // Modified: Include UID and timestamp in file name
          final String fileName = '${user.uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
          final String downloadUrl = await sb.uploadImage(imageFile, fileName: fileName);
          
          await _updateField('profile_image', downloadUrl);
          
          Fluttertoast.showToast(msg: 'Profile image updated successfully');
        }
      }
    } catch (e) {
      print('Error uploading image: $e');
      Fluttertoast.showToast(msg: 'Error uploading image: $e');
    } finally {
      setState(() {
        isUploading = false;
      });
    }
  }

  void _showEditDialog(String field, String currentValue) {
    final controller = TextEditingController(text: currentValue);
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Edit ${_getFieldDisplayName(field)}'),
          content: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: 'Enter your ${_getFieldDisplayName(field).toLowerCase()}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  _updateField(field, controller.text.trim());
                }
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showDatePicker() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    
    if (pickedDate != null) {
      final formattedDate = DateFormat('yyyy-MM-dd').format(pickedDate);
      await _updateField('dob', formattedDate);
      setState(() {
        _controllers['dob']?.text = formattedDate;
      });
    }
  }

  String _getFieldDisplayName(String field) {
    switch (field) {
      case 'name': return 'Full Name';
      case 'dob': return 'Date of Birth';
      case 'current_job': return 'Current Job';
      case 'experience': return 'Experience';
      case 'session': return 'Session';
      case 'profile_image': return 'Profile Image';
      default: return field;
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Profile'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              try {
                await FirebaseAuth.instance.signOut();
                Navigator.pushReplacement(
                  context, 
                  MaterialPageRoute(builder: (_) => const LoginPage())
                );
              } catch (e) {
                Fluttertoast.showToast(
                  msg: 'Error signing out: $e',
                  toastLength: Toast.LENGTH_SHORT,
                  gravity: ToastGravity.BOTTOM,
                  backgroundColor: Colors.red,
                );
              }
            },
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Column(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.blue,
                              width: 4.0,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.blue.withOpacity(0.3),
                                blurRadius: 10,
                                spreadRadius: 2,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Stack(
                            children: [
                              CircleAvatar(
                                radius: 70,
                                backgroundColor: Colors.grey[300],
                                backgroundImage: userData?['profile_image'] != null
                                    ? CachedNetworkImageProvider(userData!['profile_image']) as ImageProvider
                                    : null,
                                child: userData?['profile_image'] == null
                                    ? const Icon(Icons.person, size: 60, color: Colors.grey)
                                    : null,
                              ),
                              if (isUploading)
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Colors.black.withOpacity(0.5),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Center(
                                      child: CircularProgressIndicator(
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: 16),
                        
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            ElevatedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => NewsfeedPage()),
                                );
                              },
                              icon: const Icon(Icons.feed, size: 18),
                              label: const Text('Newsfeed'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15.0),
                                ),
                              ),
                            ),
                            
                            const SizedBox(width: 16),
                            
                            ElevatedButton.icon(
                              onPressed: isUploading ? null : _uploadProfileImage,
                              icon: const Icon(Icons.camera_alt, size: 18),
                              label: const Text('Upload Photo'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15.0),
                                ),
                              ),
                            ),
                          ],
                        ),
                        
                        const SizedBox(height: 16),
                        
                        SlideTransition(
                          position: _slideAnimation,
                          child: Text(
                            userData?['name'] ?? 'No Name Provided',
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Color.fromARGB(255, 226, 146, 146),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        
                        const SizedBox(height: 8),
                        
                        Text(
                          userData?['email'] ?? 'No Email Provided',
                          style: TextStyle(
                            fontSize: 17,
                            color: const Color.fromARGB(255, 60, 14, 14),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  _buildSectionHeader('Personal Information'),
                  _buildEditableInfoItem('Full Name', userData?['name'] ?? 'Not provided', 'name'),
                  _buildInfoItem('Email', userData?['email'] ?? 'Not provided'),
                  _buildEditableInfoItem('Date of Birth', userData?['dob'] ?? 'Not provided', 'dob', isDate: true),
                  
                  _buildSectionHeader('Professional Information'),
                  _buildEditableInfoItem('Current Job', userData?['current_job'] ?? 'Not provided', 'current_job'),
                  _buildEditableInfoItem('Experience', userData?['experience'] ?? 'Not provided', 'experience'),
                  _buildEditableInfoItem('Session', userData?['session'] ?? 'Not provided', 'session'),
                  
                  _buildSectionHeader('Account Information'),
                  _buildInfoItem('User ID', user?.uid ?? 'Not available'),
                  _buildInfoItem('Account Created', userData?['created_at'] ?? 'Not available'),
                  _buildInfoItem('Last Login', userData?['last_login'] ?? 'Not available'),
                  
                  const SizedBox(height: 30),
                  
                  Center(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const ProfileImagesPage()),
                        );
                      },
                      icon: const Icon(Icons.photo_library, size: 18),
                      label: const Text('All Photos'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15.0),
                        ),
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 30),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.blue,
        ),
      ),
    );
  }

  Widget _buildInfoItem(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: value == 'Not provided' || value == 'Not available' 
                    ? Colors.grey 
                    : Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditableInfoItem(String label, String value, String field, {bool isDate = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: value == 'Not provided' ? Colors.grey : Colors.black,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 18, color: Colors.blue),
            onPressed: () {
              if (isDate) {
                _showDatePicker();
              } else {
                _showEditDialog(field, value);
              }
            },
          ),
        ],
      ),
    );
  }
}