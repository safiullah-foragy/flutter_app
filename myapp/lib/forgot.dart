import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fluttertoast/fluttertoast.dart';

class ForgotPage extends StatefulWidget {
  const ForgotPage({super.key});

  @override
  State<ForgotPage> createState() => _ForgotPageState();
}

class _ForgotPageState extends State<ForgotPage> with SingleTickerProviderStateMixin {
  final TextEditingController emailController = TextEditingController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  late AnimationController _controller;
  late Animation<Color?> _colorAnimation;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat(reverse: true);
    
    _colorAnimation = TweenSequence<Color?>([
      TweenSequenceItem(
        tween: ColorTween(
          begin: const Color(0xFF0A0E21),
          end: const Color(0xFF1A1F38),
        ),
        weight: 25.0,
      ),
      TweenSequenceItem(
        tween: ColorTween(
          begin: const Color(0xFF1A1F38),
          end: const Color(0xFF2A1B3D),
        ),
        weight: 25.0,
      ),
      TweenSequenceItem(
        tween: ColorTween(
          begin: const Color(0xFF2A1B3D),
          end: const Color(0xFF0F2A44),
        ),
        weight: 25.0,
      ),
      TweenSequenceItem(
        tween: ColorTween(
          begin: const Color(0xFF0F2A44),
          end: const Color(0xFF0A0E21),
        ),
        weight: 25.0,
      ),
    ]).animate(_controller)
      ..addListener(() {
        setState(() {});
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    emailController.dispose();
    super.dispose();
  }

  void resetPassword() async {
    String email = emailController.text.trim();
    if (email.isEmpty) {
      Fluttertoast.showToast(msg: 'Enter your email');
      return;
    }
    
    if (!email.contains('@')) {
      Fluttertoast.showToast(msg: 'Please enter a valid email address');
      return;
    }
    
    setState(() {
      _isLoading = true;
    });
    
    try {
      await _auth.sendPasswordResetEmail(email: email);
      Fluttertoast.showToast(msg: 'Password reset email sent');
      await Future.delayed(const Duration(milliseconds: 500));
      Navigator.pop(context);
    } catch (e) {
      Fluttertoast.showToast(msg: 'Error: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Forgot Password'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              return Container(
                width: double.infinity,
                height: double.infinity,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _colorAnimation.value!,
                      _colorAnimation.value!.withOpacity(0.8),
                      const Color(0xFF151A30),
                      const Color.fromARGB(255, 55, 31, 87),
                    ],
                  ),
                ),
              );
            },
          ),
          
          Center(
            child: SingleChildScrollView(
              child: Container(
                width: MediaQuery.of(context).size.width * 0.85,
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 20),
                    const Icon(
                      Icons.lock_reset,
                      size: 60,
                      color: Colors.deepPurple,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Reset Password',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.deepPurple,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Enter your email to receive a password reset link',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 25),

                    // Email Field
                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: 'Email',
                        hintText: 'Enter your email',
                        prefixIcon: Icon(
                          Icons.email,
                          color: Colors.deepPurple.shade800,
                        ),
                        isDense: false,
                        contentPadding: const EdgeInsets.symmetric(vertical: 16),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),

                    const SizedBox(height: 30),
                    
                    _isLoading
                        ? const CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.deepPurple),
                          )
                        : SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: resetPassword,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.deepPurple,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                elevation: 5,
                              ),
                              child: const Text(
                                'Send Reset Email',
                                style: TextStyle(fontSize: 16),
                              ),
                            ),
                          ),

                    const SizedBox(height: 20),
                    
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'Back to Login',
                        style: TextStyle(
                          color: Colors.deepPurple,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}