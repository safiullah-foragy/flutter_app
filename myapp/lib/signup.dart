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

class _SignupPageState extends State<SignupPage> with SingleTickerProviderStateMixin {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  final TextEditingController nameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController sessionController = TextEditingController();
  final TextEditingController dobController = TextEditingController();
  final TextEditingController currentJobController = TextEditingController();
  final TextEditingController experienceController = TextEditingController();

  late AnimationController _controller;
  late Animation<Color?> _colorAnimation;
  bool _isLoading = false;
  bool _obscurePassword = true;
  DateTime? _selectedDate;
  bool _isEmailValid = true;
  bool _isPasswordValid = false;
  int _passwordStrength = 0;

  // Password requirements
  bool _hasMinLength = false;
  bool _hasUppercase = false;
  bool _hasLowercase = false;
  bool _hasNumber = false;
  bool _hasSpecialChar = false;

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

    // Add listeners for validation
    emailController.addListener(_validateEmail);
    passwordController.addListener(_validatePassword);
  }

  void _validateEmail() {
    setState(() {
      _isEmailValid = emailController.text.contains('@') && 
                     emailController.text.contains('.') &&
                     emailController.text.length > 5;
    });
  }

  void _validatePassword() {
    String password = passwordController.text;
    
    setState(() {
      _hasMinLength = password.length >= 6;
      _hasUppercase = password.contains(RegExp(r'[A-Z]'));
      _hasLowercase = password.contains(RegExp(r'[a-z]'));
      _hasNumber = password.contains(RegExp(r'[0-9]'));
      _hasSpecialChar = password.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));
      
      // Calculate password strength (0-5)
      _passwordStrength = 0;
      if (_hasMinLength) _passwordStrength++;
      if (_hasUppercase) _passwordStrength++;
      if (_hasLowercase) _passwordStrength++;
      if (_hasNumber) _passwordStrength++;
      if (_hasSpecialChar) _passwordStrength++;
      
      _isPasswordValid = _passwordStrength >= 3;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    sessionController.dispose();
    dobController.dispose();
    currentJobController.dispose();
    experienceController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        dobController.text = DateFormat('yyyy-MM-dd').format(picked);
      });
    }
  }

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

    if (!_isEmailValid) {
      Fluttertoast.showToast(msg: 'Please enter a valid email address');
      return;
    }

    if (!_isPasswordValid) {
      Fluttertoast.showToast(msg: 'Password is not strong enough');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      UserCredential user = await _auth.createUserWithEmailAndPassword(
          email: email, password: password);

      // Store user data in Firestore
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
      await Future.delayed(const Duration(milliseconds: 500));
      
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
    } catch (e) {
      Fluttertoast.showToast(msg: 'Signup Failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Color _getPasswordBorderColor() {
    if (passwordController.text.isEmpty) {
      return Colors.grey;
    } else if (!_hasMinLength) {
      return Colors.red;
    } else if (_passwordStrength < 3) {
      return Colors.orange;
    } else {
      return Colors.green;
    }
  }

  Color _getEmailBorderColor() {
    if (emailController.text.isEmpty) {
      return Colors.grey;
    } else if (!_isEmailValid) {
      return Colors.red;
    } else {
      return Colors.green;
    }
  }

  Widget _buildPasswordRequirement(bool met, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.circle,
            color: met ? Colors.green : Colors.grey,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: met ? Colors.green : Colors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
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
                width: MediaQuery.of(context).size.width * 0.9,
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Password Strength Indicator Sidebar
                    if (passwordController.text.isNotEmpty) 
                      Container(
                        width: 8,
                        height: 200,
                        margin: const EdgeInsets.only(right: 15, top: 100),
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Expanded(
                              flex: 5 - _passwordStrength,
                              child: Container(),
                            ),
                            Expanded(
                              flex: _passwordStrength,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _passwordStrength < 2 
                                    ? Colors.red 
                                    : _passwordStrength < 4 
                                      ? Colors.orange 
                                      : Colors.green,
                                  borderRadius: const BorderRadius.only(
                                    bottomLeft: Radius.circular(4),
                                    bottomRight: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 20),
                          const Icon(
                            Icons.person_add,
                            size: 60,
                            color: Colors.deepPurple,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Create Account',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.deepPurple,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Fill in your details to get started',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 25),

                          // Name Field
                          TextField(
                            controller: nameController,
                            decoration: InputDecoration(
                              labelText: 'Full Name',
                              hintText: 'Enter your full name',
                              prefixIcon: Icon(
                                Icons.person,
                                color: Colors.deepPurple.shade800,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),

                          const SizedBox(height: 15),

                          // Email Field with validation
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
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: _getEmailBorderColor(),
                                  width: 2.0,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: _getEmailBorderColor(),
                                  width: 2.0,
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(height: 15),

                          // Password Field with validation
                          TextField(
                            controller: passwordController,
                            obscureText: _obscurePassword,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              hintText: 'Enter your password',
                              prefixIcon: Icon(
                                Icons.lock,
                                color: Colors.deepPurple.shade800,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                                  color: Colors.deepPurple.shade800,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: _getPasswordBorderColor(),
                                  width: 2.0,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(
                                  color: _getPasswordBorderColor(),
                                  width: 2.0,
                                ),
                              ),
                            ),
                          ),

                          // Password Requirements
                          if (passwordController.text.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _buildPasswordRequirement(_hasMinLength, 'At least 6 characters'),
                                _buildPasswordRequirement(_hasUppercase, 'Contains uppercase letter'),
                                _buildPasswordRequirement(_hasLowercase, 'Contains lowercase letter'),
                                _buildPasswordRequirement(_hasNumber, 'Contains number'),
                                _buildPasswordRequirement(_hasSpecialChar, 'Contains special character'),
                              ],
                            ),
                          ],

                          const SizedBox(height: 15),

                          // Session Field
                          TextField(
                            controller: sessionController,
                            decoration: InputDecoration(
                              labelText: 'Session',
                              hintText: 'e.g., 2020-2024',
                              prefixIcon: Icon(
                                Icons.school,
                                color: Colors.deepPurple.shade800,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),

                          const SizedBox(height: 15),

                          // Date of Birth Field with Date Picker
                          TextField(
                            controller: dobController,
                            readOnly: true,
                            decoration: InputDecoration(
                              labelText: 'Date of Birth',
                              hintText: 'Select your date of birth',
                              prefixIcon: Icon(
                                Icons.calendar_today,
                                color: Colors.deepPurple.shade800,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  Icons.calendar_month,
                                  color: Colors.deepPurple.shade800,
                                ),
                                onPressed: () => _selectDate(context),
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            onTap: () => _selectDate(context),
                          ),

                          const SizedBox(height: 15),

                          // Current Job Field
                          TextField(
                            controller: currentJobController,
                            decoration: InputDecoration(
                              labelText: 'Current Job',
                              hintText: 'Enter your current job',
                              prefixIcon: Icon(
                                Icons.work,
                                color: Colors.deepPurple.shade800,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),

                          const SizedBox(height: 15),

                          // Experience Field
                          TextField(
                            controller: experienceController,
                            decoration: InputDecoration(
                              labelText: 'Experience Duration',
                              hintText: 'e.g., 2 years',
                              prefixIcon: Icon(
                                Icons.timeline,
                                color: Colors.deepPurple.shade800,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),

                          const SizedBox(height: 25),
                          
                          _isLoading
                              ? const CircularProgressIndicator(
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.deepPurple),
                                )
                              : SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: signup,
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
                                      'Sign Up',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ),

                          const SizedBox(height: 20),
                          
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                'Already have an account? ',
                                style: TextStyle(color: Colors.grey),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(builder: (context) => const LoginPage()),
                                ),
                                child: const Text(
                                  'Login',
                                  style: TextStyle(
                                    color: Colors.deepPurple,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                        ],
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