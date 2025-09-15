import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'login.dart';
import 'package:intl/intl.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final TextEditingController nameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController sessionController = TextEditingController();
  final TextEditingController dobController = TextEditingController();
  final TextEditingController currentJobController = TextEditingController();
  final TextEditingController experienceController = TextEditingController();

  void signup() async {
    String name = nameController.text.trim();
    String email = emailController.text.trim();
    String password = passwordController.text.trim();
    String session = sessionController.text.trim();
    String dob = dobController.text.trim();
    String job = currentJobController.text.trim();
    String exp = experienceController.text.trim();

    if ([name, email, password, session, dob, job, exp].any((e) => e.isEmpty)) {
      Fluttertoast.showToast(msg: 'Please fill all fields');
      return;
    }

    try {
      UserCredential user = await _auth.createUserWithEmailAndPassword(
          email: email, password: password);

      await _firestore.collection('users').doc(user.user!.uid).set({
        'name': name,
        'email': email,
        'session': session,
        'dob': dob,
        'current_job': job,
        'experience': exp,
        'created_at': DateFormat('yyyy-MM-dd').format(DateTime.now()),
      });

      Fluttertoast.showToast(msg: 'Signup Successful');
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
    } catch (e) {
      Fluttertoast.showToast(msg: 'Signup Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Signup')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: emailController, decoration: const InputDecoration(labelText: 'Email')),
            TextField(controller: passwordController, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
            TextField(controller: sessionController, decoration: const InputDecoration(labelText: 'Session')),
            TextField(controller: dobController, decoration: const InputDecoration(labelText: 'Date of Birth')),
            TextField(controller: currentJobController, decoration: const InputDecoration(labelText: 'Current Job')),
            TextField(controller: experienceController, decoration: const InputDecoration(labelText: 'Experience Duration')),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: signup, child: const Text('Signup')),
          ],
        ),
      ),
    );
  }
}
