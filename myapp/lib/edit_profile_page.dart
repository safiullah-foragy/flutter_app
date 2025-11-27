import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';

class EditProfilePage extends StatefulWidget {
  final Map<String, dynamic>? userData;
  
  const EditProfilePage({super.key, this.userData});

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final _formKey = GlobalKey<FormState>();
  
  bool _isLoading = false;

  // Controllers for all fields
  late TextEditingController _nameController;
  late TextEditingController _bioController;
  late TextEditingController _phoneController;
  late TextEditingController _locationController;
  late TextEditingController _websiteController;
  late TextEditingController _dobController;
  
  // Education
  late TextEditingController _schoolController;
  late TextEditingController _schoolYearController;
  late TextEditingController _collegeController;
  late TextEditingController _collegeYearController;
  late TextEditingController _universityController;
  late TextEditingController _universityYearController;
  late TextEditingController _fieldOfStudyController;
  
  // Work
  late TextEditingController _currentJobController;
  late TextEditingController _currentCompanyController;
  late TextEditingController _currentJobStartController;
  late TextEditingController _previousJobController;
  late TextEditingController _previousCompanyController;
  late TextEditingController _previousJobYearController;
  late TextEditingController _experienceController;
  
  bool _studyingCurrently = false;
  bool _workingCurrently = false;

  @override
  void initState() {
    super.initState();
    final data = widget.userData ?? {};
    
    _nameController = TextEditingController(text: data['name'] ?? '');
    _bioController = TextEditingController(text: data['bio'] ?? data['about'] ?? '');
    _phoneController = TextEditingController(text: data['phone'] ?? '');
    _locationController = TextEditingController(text: data['location'] ?? '');
    _websiteController = TextEditingController(text: data['website'] ?? '');
    _dobController = TextEditingController(text: data['dob'] ?? '');
    
    // Education
    _schoolController = TextEditingController(text: data['school'] ?? '');
    _schoolYearController = TextEditingController(text: data['school_year'] ?? '');
    _collegeController = TextEditingController(text: data['college'] ?? '');
    _collegeYearController = TextEditingController(text: data['college_year'] ?? '');
    _universityController = TextEditingController(text: data['university'] ?? '');
    _universityYearController = TextEditingController(text: data['university_year'] ?? '');
    _fieldOfStudyController = TextEditingController(text: data['field_of_study'] ?? '');
    _studyingCurrently = data['studying_currently'] ?? false;
    
    // Work
    _currentJobController = TextEditingController(text: data['current_job'] ?? '');
    _currentCompanyController = TextEditingController(text: data['current_company'] ?? '');
    _currentJobStartController = TextEditingController(text: data['current_job_start'] ?? '');
    _previousJobController = TextEditingController(text: data['previous_job'] ?? '');
    _previousCompanyController = TextEditingController(text: data['previous_company'] ?? '');
    _previousJobYearController = TextEditingController(text: data['previous_job_year'] ?? '');
    _experienceController = TextEditingController(text: data['experience'] ?? '');
    _workingCurrently = data['working_currently'] ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _bioController.dispose();
    _phoneController.dispose();
    _locationController.dispose();
    _websiteController.dispose();
    _dobController.dispose();
    _schoolController.dispose();
    _schoolYearController.dispose();
    _collegeController.dispose();
    _collegeYearController.dispose();
    _universityController.dispose();
    _universityYearController.dispose();
    _fieldOfStudyController.dispose();
    _currentJobController.dispose();
    _currentCompanyController.dispose();
    _currentJobStartController.dispose();
    _previousJobController.dispose();
    _previousCompanyController.dispose();
    _previousJobYearController.dispose();
    _experienceController.dispose();
    super.dispose();
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        controller.text = DateFormat('yyyy-MM-dd').format(picked);
      });
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isLoading = true);
    
    try {
      final User? user = _auth.currentUser;
      if (user == null) throw Exception('No user logged in');
      
      final data = <String, dynamic>{
        'name': _nameController.text.trim(),
        'bio': _bioController.text.trim(),
        'phone': _phoneController.text.trim(),
        'location': _locationController.text.trim(),
        'website': _websiteController.text.trim(),
        'dob': _dobController.text.trim(),
        
        // Education
        'school': _schoolController.text.trim(),
        'school_year': _schoolYearController.text.trim(),
        'college': _collegeController.text.trim(),
        'college_year': _collegeYearController.text.trim(),
        'university': _universityController.text.trim(),
        'university_year': _universityYearController.text.trim(),
        'field_of_study': _fieldOfStudyController.text.trim(),
        'studying_currently': _studyingCurrently,
        
        // Work
        'current_job': _currentJobController.text.trim(),
        'current_company': _currentCompanyController.text.trim(),
        'current_job_start': _currentJobStartController.text.trim(),
        'previous_job': _previousJobController.text.trim(),
        'previous_company': _previousCompanyController.text.trim(),
        'previous_job_year': _previousJobYearController.text.trim(),
        'experience': _experienceController.text.trim(),
        'working_currently': _workingCurrently,
      };
      
      await _firestore.collection('users').doc(user.uid).update(data);
      
      if (!mounted) return;
      Fluttertoast.showToast(msg: 'Profile updated successfully!');
      Navigator.pop(context, true); // Return true to indicate success
    } catch (e) {
      if (!mounted) return;
      Fluttertoast.showToast(msg: 'Error updating profile: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Profile'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _saveProfile,
              tooltip: 'Save',
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Basic Information
            _buildSectionHeader('Basic Information', Icons.person),
            _buildTextField(
              controller: _nameController,
              label: 'Full Name',
              icon: Icons.person,
              validator: (value) =>
                  value?.isEmpty ?? true ? 'Name is required' : null,
            ),
            _buildTextField(
              controller: _bioController,
              label: 'Bio / About',
              icon: Icons.info,
              maxLines: 3,
            ),
            _buildTextField(
              controller: _phoneController,
              label: 'Phone Number',
              icon: Icons.phone,
              keyboardType: TextInputType.phone,
            ),
            _buildTextField(
              controller: _locationController,
              label: 'Location',
              icon: Icons.location_on,
            ),
            _buildTextField(
              controller: _websiteController,
              label: 'Website',
              icon: Icons.language,
              keyboardType: TextInputType.url,
            ),
            _buildDateField(
              controller: _dobController,
              label: 'Date of Birth',
            ),
            
            const SizedBox(height: 24),
            
            // Education
            _buildSectionHeader('Education', Icons.school),
            _buildTextField(
              controller: _schoolController,
              label: 'School Name',
              icon: Icons.school,
            ),
            _buildTextField(
              controller: _schoolYearController,
              label: 'School Year (e.g., 2010-2015)',
              icon: Icons.date_range,
            ),
            _buildTextField(
              controller: _collegeController,
              label: 'College Name',
              icon: Icons.school,
            ),
            _buildTextField(
              controller: _collegeYearController,
              label: 'College Year (e.g., 2015-2017)',
              icon: Icons.date_range,
            ),
            _buildTextField(
              controller: _universityController,
              label: 'University Name',
              icon: Icons.school,
            ),
            _buildTextField(
              controller: _universityYearController,
              label: 'University Year (e.g., 2017-2021)',
              icon: Icons.date_range,
            ),
            _buildTextField(
              controller: _fieldOfStudyController,
              label: 'Field of Study / Major',
              icon: Icons.menu_book,
            ),
            SwitchListTile(
              title: const Text('Currently Studying'),
              value: _studyingCurrently,
              onChanged: (value) => setState(() => _studyingCurrently = value),
              secondary: const Icon(Icons.school),
            ),
            
            const SizedBox(height: 24),
            
            // Work Experience
            _buildSectionHeader('Work Experience', Icons.work),
            _buildTextField(
              controller: _currentJobController,
              label: 'Current Job Title',
              icon: Icons.work,
            ),
            _buildTextField(
              controller: _currentCompanyController,
              label: 'Current Company',
              icon: Icons.business,
            ),
            _buildTextField(
              controller: _currentJobStartController,
              label: 'Started Since (e.g., Jan 2023)',
              icon: Icons.calendar_today,
            ),
            _buildTextField(
              controller: _previousJobController,
              label: 'Previous Job Title',
              icon: Icons.work_history,
            ),
            _buildTextField(
              controller: _previousCompanyController,
              label: 'Previous Company',
              icon: Icons.business_center,
            ),
            _buildTextField(
              controller: _previousJobYearController,
              label: 'Previous Job Duration',
              icon: Icons.date_range,
            ),
            _buildTextField(
              controller: _experienceController,
              label: 'Total Experience (e.g., 5 years)',
              icon: Icons.timeline,
            ),
            SwitchListTile(
              title: const Text('Currently Working'),
              value: _workingCurrently,
              onChanged: (value) => setState(() => _workingCurrently = value),
              secondary: const Icon(Icons.work),
            ),
            
            const SizedBox(height: 32),
            
            // Save Button
            SizedBox(
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _isLoading ? null : _saveProfile,
                icon: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Icon(Icons.save),
                label: Text(_isLoading ? 'Saving...' : 'Save Profile'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(top: 8.0, bottom: 16.0),
      child: Row(
        children: [
          Icon(icon, color: Colors.blue, size: 28),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.blue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: TextFormField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          filled: true,
          fillColor: Colors.grey[50],
        ),
        maxLines: maxLines,
        keyboardType: keyboardType,
        validator: validator,
      ),
    );
  }

  Widget _buildDateField({
    required TextEditingController controller,
    required String label,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: TextFormField(
        controller: controller,
        readOnly: true,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.calendar_today),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          filled: true,
          fillColor: Colors.grey[50],
        ),
        onTap: () => _selectDate(controller),
      ),
    );
  }
}
