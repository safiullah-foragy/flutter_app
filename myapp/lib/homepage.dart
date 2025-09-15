import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'login.dart';
import 'package:intl/intl.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  Map<String, dynamic>? userData;
  bool isLoading = true;
  final Map<String, TextEditingController> _controllers = {};

  @override
  void initState() {
    super.initState();
    _fetchUserData();
    _updateLastLogin();
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
            
            // Initialize controllers with current values
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

  Future<void> _updateField(String field, String value) async {
    try {
      final User? user = _auth.currentUser;
      if (user != null) {
        await _firestore.collection('users').doc(user.uid).update({
          field: value,
        });
        
        setState(() {
          userData?[field] = value;
        });
        
        Fluttertoast.showToast(msg: '$field updated successfully');
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error updating $field: $e');
    }
  }

  void _showEditDialog(String field, String currentValue) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Edit ${_getFieldDisplayName(field)}'),
          content: TextField(
            controller: TextEditingController(text: currentValue),
            onChanged: (value) {
              _controllers[field]?.text = value;
            },
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
                _updateField(field, _controllers[field]?.text ?? currentValue);
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  void _showDatePicker() {
    showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    ).then((pickedDate) {
      if (pickedDate != null) {
        final formattedDate = DateFormat('yyyy-MM-dd').format(pickedDate);
        _updateField('dob', formattedDate);
        setState(() {
          _controllers['dob']?.text = formattedDate;
        });
      }
    });
  }

  String _getFieldDisplayName(String field) {
    switch (field) {
      case 'name': return 'Full Name';
      case 'dob': return 'Date of Birth';
      case 'current_job': return 'Current Job';
      case 'experience': return 'Experience';
      case 'session': return 'Session';
      default: return field;
    }
  }

  @override
  void dispose() {
    // Dispose all controllers
    _controllers.forEach((key, controller) {
      controller.dispose();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('User Profile'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              Navigator.pushReplacement(
                context, 
                MaterialPageRoute(builder: (_) => const LoginPage())
              );
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
                  // Profile Header
                  Center(
                    child: Column(
                      children: [
                        const CircleAvatar(
                          radius: 50,
                          child: Icon(Icons.person, size: 40),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          userData?['name'] ?? 'No Name Provided',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          userData?['email'] ?? 'No Email Provided',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  // Personal Information Section
                  _buildSectionHeader('Personal Information'),
                  _buildEditableInfoItem('Full Name', userData?['name'] ?? 'Not provided', 'name'),
                  _buildInfoItem('Email', userData?['email'] ?? 'Not provided'),
                  _buildEditableInfoItem('Date of Birth', userData?['dob'] ?? 'Not provided', 'dob', isDate: true),
                  
                  // Professional Information Section
                  _buildSectionHeader('Professional Information'),
                  _buildEditableInfoItem('Current Job', userData?['current_job'] ?? 'Not provided', 'current_job'),
                  _buildEditableInfoItem('Experience', userData?['experience'] ?? 'Not provided', 'experience'),
                  _buildEditableInfoItem('Session', userData?['session'] ?? 'Not provided', 'session'),
                  
                  // Account Information Section
                  _buildSectionHeader('Account Information'),
                  _buildInfoItem('User ID', user?.uid ?? 'Not available'),
                  _buildInfoItem('Account Created', userData?['created_at'] ?? 'Not available'),
                  _buildInfoItem('Last Login', userData?['last_login'] ?? 'Not available'),
                  
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
          Expanded(child: Text(value)),
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
          Expanded(child: Text(value)),
          IconButton(
            icon: const Icon(Icons.edit, size: 18),
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