import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'models/cv_model.dart';
import 'services/cv_service.dart';

class CVGeneratorPage extends StatefulWidget {
  final Map<String, dynamic>? userData;
  const CVGeneratorPage({super.key, this.userData});

  @override
  State<CVGeneratorPage> createState() => _CVGeneratorPageState();
}

class _CVGeneratorPageState extends State<CVGeneratorPage> {
  final _formKey = GlobalKey<FormState>();
  final CVFormData _formData = CVFormData();
  final List<PreviousJob> _previousJobs = [];
  final ImagePicker _imagePicker = ImagePicker();
  File? _photoFile;
  bool _isLoading = false;
  bool _isDataLoaded = false;
  List<GeneratedCV>? _generatedCVs;
  List<int> _selectedTemplates = [];

  // Controllers for previous job inputs
  final TextEditingController _jobTitleController = TextEditingController();
  final TextEditingController _jobCompanyController = TextEditingController();
  final TextEditingController _jobDurationController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initUserData();
  }

  void _populateFromData(Map<String, dynamic> data) {
    final user = FirebaseAuth.instance.currentUser;
    _formData.name = data['name'] ?? user?.displayName ?? '';
    _formData.email = data['email'] ?? user?.email ?? '';
    _formData.phone = data['phone'] ?? user?.phoneNumber ?? '';
    _formData.presentAddress = data['location'] ?? '';
    _formData.dateOfBirth = data['dob'] ?? '';
    _formData.website = data['website'] ?? '';
    _formData.summary = data['bio'] ?? data['about'] ?? '';
    
    // Education
    _formData.sscSchool = data['school'] ?? '';
    _formData.sscYear = data['school_year'] ?? '';
    _formData.hscCollege = data['college'] ?? '';
    _formData.hscYear = data['college_year'] ?? '';
    _formData.graduationInstitution = data['university'] ?? '';
    _formData.graduationYear = data['university_year'] ?? '';
    _formData.graduationSubject = data['field_of_study'] ?? '';
    
    // Current Job
    final hasJob = data['working_currently'] == true ||
        (data['current_job'] != null && data['current_job'].toString().trim().isNotEmpty);
    _formData.currentJob = hasJob;
    _formData.currentJobTitle = data['current_job'] ?? '';
    _formData.currentJobCompany = data['current_company'] ?? '';
    _formData.currentJobDuration = data['current_job_start'] ?? '';
    _formData.currentJobResponsibilities = data['experience'] ?? '';

    // Previous Job if exists
    if (data['previous_job'] != null && data['previous_job'].toString().trim().isNotEmpty) {
      if (_previousJobs.isEmpty) {
        _previousJobs.add(PreviousJob(
          jobTitle: data['previous_job'].toString(),
          jobCompany: data['previous_company']?.toString() ?? '',
          jobDuration: data['previous_job_year']?.toString() ?? '',
        ));
      }
    }
  }

  Future<void> _initUserData() async {
    if (widget.userData != null && widget.userData!.isNotEmpty) {
      _populateFromData(widget.userData!);
      setState(() {
        _isDataLoaded = true;
      });
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
        if (doc.exists && doc.data() != null) {
          _populateFromData(doc.data()!);
        } else {
          _formData.name = user.displayName ?? '';
          _formData.email = user.email ?? '';
          _formData.phone = user.phoneNumber ?? '';
        }
      } catch (_) {
        _formData.name = user.displayName ?? '';
        _formData.email = user.email ?? '';
        _formData.phone = user.phoneNumber ?? '';
      }
    }
    if (mounted) {
      setState(() {
        _isDataLoaded = true;
      });
    }
  }

  @override
  void dispose() {
    _jobTitleController.dispose();
    _jobCompanyController.dispose();
    _jobDurationController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      
      if (image != null) {
        setState(() {
          _photoFile = File(image.path);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking photo: $e')),
      );
    }
  }

  void _addPreviousJob() {
    if (_jobTitleController.text.isNotEmpty &&
        _jobCompanyController.text.isNotEmpty &&
        _jobDurationController.text.isNotEmpty) {
      setState(() {
        _previousJobs.add(PreviousJob(
          jobTitle: _jobTitleController.text,
          jobCompany: _jobCompanyController.text,
          jobDuration: _jobDurationController.text,
        ));
        _jobTitleController.clear();
        _jobCompanyController.clear();
        _jobDurationController.clear();
      });
    }
  }

  void _removePreviousJob(int index) {
    setState(() {
      _previousJobs.removeAt(index);
    });
  }

  Future<void> _generateCV() async {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all required fields')),
      );
      return;
    }

    if (_selectedTemplates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one template')),
      );
      return;
    }

    _formKey.currentState!.save();
    _formData.previousJobs = List.from(_previousJobs);

    setState(() {
      _isLoading = true;
    });

    try {
      final cvs = await CVService.generateCV(
        formData: _formData,
        selectedTemplates: _selectedTemplates,
        photo: _photoFile,
      );

      setState(() {
        _generatedCVs = cvs;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  void _reset() {
    setState(() {
      _generatedCVs = null;
      _formKey.currentState?.reset();
      _previousJobs.clear();
      _photoFile = null;
      _selectedTemplates.clear();
    });
  }

  Future<void> _launchUrl(String url) async {
    final fullUrl = '${CVService.baseUrl}$url';
    final uri = Uri.parse(fullUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open URL')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_generatedCVs != null) {
      return _buildResultsView();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('CV Generator'),
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Colors.purple, Colors.blue],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Column(
                        children: [
                          Text(
                            '📝 Professional CV Generator',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Create your perfect CV in multiple formats',
                            style: TextStyle(color: Colors.white70, fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Auto-fill notice banner
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.purple.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.purple.withOpacity(0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.auto_fix_high_rounded, color: Colors.purple, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Your account info has been auto-filled below. You can keep or edit any field.',
                              style: TextStyle(color: Colors.purple[900], fontSize: 13, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Photo Upload
                    _buildSectionTitle('📷 Photo'),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            if (_photoFile != null)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  _photoFile!,
                                  height: 150,
                                  width: 150,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: _pickPhoto,
                              icon: const Icon(Icons.photo_camera),
                              label: Text(_photoFile == null ? 'Select Photo' : 'Change Photo'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Personal Information
                    _buildSectionTitle('📋 Personal Information'),
                    _buildTextField('Full Name', (val) => _formData.name = val ?? '', initialValue: _formData.name, required: true),
                    _buildTextField('Father\'s Name', (val) => _formData.fatherName = val ?? '', initialValue: _formData.fatherName),
                    _buildTextField('Mother\'s Name', (val) => _formData.motherName = val ?? '', initialValue: _formData.motherName),
                    _buildTextField('Present Address', (val) => _formData.presentAddress = val ?? '', initialValue: _formData.presentAddress),
                    _buildTextField('Permanent Address', (val) => _formData.permanentAddress = val ?? '', initialValue: _formData.permanentAddress),
                    _buildTextField('Date of Birth', (val) => _formData.dateOfBirth = val ?? '', initialValue: _formData.dateOfBirth, required: true),
                    _buildTextField('Age', (val) => _formData.age = val ?? '', initialValue: _formData.age),
                    _buildTextField('Gender', (val) => _formData.gender = val ?? '', initialValue: _formData.gender, required: true),
                    _buildTextField('Marital Status', (val) => _formData.maritalStatus = val ?? '', initialValue: _formData.maritalStatus),
                    _buildTextField('Nationality', (val) => _formData.nationality = val ?? '', initialValue: _formData.nationality),
                    _buildTextField('NID', (val) => _formData.nid = val ?? '', initialValue: _formData.nid),
                    _buildTextField('Passport', (val) => _formData.passport = val ?? '', initialValue: _formData.passport),
                    _buildTextField('Religion', (val) => _formData.religion = val ?? '', initialValue: _formData.religion),

                    const SizedBox(height: 24),

                    // Contact Information
                    _buildSectionTitle('📞 Contact Information'),
                    _buildTextField('Email', (val) => _formData.email = val ?? '', initialValue: _formData.email, required: true, keyboardType: TextInputType.emailAddress),
                    _buildTextField('Phone', (val) => _formData.phone = val ?? '', initialValue: _formData.phone, required: true, keyboardType: TextInputType.phone),
                    _buildTextField('Alternate Phone', (val) => _formData.alternatePhone = val ?? '', initialValue: _formData.alternatePhone, keyboardType: TextInputType.phone),
                    _buildTextField('LinkedIn', (val) => _formData.linkedIn = val ?? '', initialValue: _formData.linkedIn),
                    _buildTextField('Website', (val) => _formData.website = val ?? '', initialValue: _formData.website),

                    const SizedBox(height: 24),

                    // Education - SSC
                    _buildSectionTitle('🎓 SSC Education'),
                    _buildTextField('SSC GPA', (val) => _formData.sscGpa = val ?? '', initialValue: _formData.sscGpa, required: true),
                    _buildTextField('SSC School', (val) => _formData.sscSchool = val ?? '', initialValue: _formData.sscSchool),
                    _buildTextField('SSC Board', (val) => _formData.sscBoard = val ?? '', initialValue: _formData.sscBoard),
                    _buildTextField('SSC Year', (val) => _formData.sscYear = val ?? '', initialValue: _formData.sscYear),
                    _buildTextField('SSC Group', (val) => _formData.sscGroup = val ?? '', initialValue: _formData.sscGroup),

                    const SizedBox(height: 24),

                    // Education - HSC
                    _buildSectionTitle('🎓 HSC Education'),
                    _buildTextField('HSC GPA', (val) => _formData.hscGpa = val ?? '', initialValue: _formData.hscGpa, required: true),
                    _buildTextField('HSC College', (val) => _formData.hscCollege = val ?? '', initialValue: _formData.hscCollege),
                    _buildTextField('HSC Board', (val) => _formData.hscBoard = val ?? '', initialValue: _formData.hscBoard),
                    _buildTextField('HSC Year', (val) => _formData.hscYear = val ?? '', initialValue: _formData.hscYear),
                    _buildTextField('HSC Group', (val) => _formData.hscGroup = val ?? '', initialValue: _formData.hscGroup),

                    const SizedBox(height: 24),

                    // Education - Graduation
                    _buildSectionTitle('🎓 Graduation'),
                    _buildTextField('Degree', (val) => _formData.graduationDegree = val ?? '', initialValue: _formData.graduationDegree),
                    _buildTextField('Subject/Major', (val) => _formData.graduationSubject = val ?? '', initialValue: _formData.graduationSubject),
                    _buildTextField('CGPA', (val) => _formData.graduationCgpa = val ?? '', initialValue: _formData.graduationCgpa, required: true),
                    _buildTextField('Institution', (val) => _formData.graduationInstitution = val ?? '', initialValue: _formData.graduationInstitution),
                    _buildTextField('Year', (val) => _formData.graduationYear = val ?? '', initialValue: _formData.graduationYear),

                    const SizedBox(height: 24),

                    // Current Job
                    _buildSectionTitle('💼 Current Job'),
                    CheckboxListTile(
                      title: const Text('I am currently employed'),
                      value: _formData.currentJob,
                      onChanged: (val) {
                        setState(() {
                          _formData.currentJob = val ?? false;
                        });
                      },
                    ),
                    if (_formData.currentJob) ...[
                      _buildTextField('Job Title', (val) => _formData.currentJobTitle = val ?? '', initialValue: _formData.currentJobTitle),
                      _buildTextField('Company', (val) => _formData.currentJobCompany = val ?? '', initialValue: _formData.currentJobCompany),
                      _buildTextField('Duration', (val) => _formData.currentJobDuration = val ?? '', initialValue: _formData.currentJobDuration),
                      _buildTextField('Location', (val) => _formData.currentJobLocation = val ?? '', initialValue: _formData.currentJobLocation),
                      _buildTextField('Responsibilities', (val) => _formData.currentJobResponsibilities = val ?? '', initialValue: _formData.currentJobResponsibilities, maxLines: 3),
                    ],

                    const SizedBox(height: 24),

                    // Previous Jobs
                    _buildSectionTitle('💼 Previous Jobs'),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            TextField(
                              controller: _jobTitleController,
                              decoration: const InputDecoration(labelText: 'Job Title'),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _jobCompanyController,
                              decoration: const InputDecoration(labelText: 'Company'),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _jobDurationController,
                              decoration: const InputDecoration(labelText: 'Duration'),
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: _addPreviousJob,
                              icon: const Icon(Icons.add),
                              label: const Text('Add Previous Job'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_previousJobs.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ..._previousJobs.asMap().entries.map((entry) {
                        final index = entry.key;
                        final job = entry.value;
                        return Card(
                          child: ListTile(
                            title: Text(job.jobTitle),
                            subtitle: Text('${job.jobCompany} | ${job.jobDuration}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _removePreviousJob(index),
                            ),
                          ),
                        );
                      }),
                    ],

                    const SizedBox(height: 24),

                    // Skills & Additional Info
                    _buildSectionTitle('⚡ Skills & Additional Information'),
                    _buildTextField('Skills', (val) => _formData.skills = val ?? '', initialValue: _formData.skills, maxLines: 3),
                    _buildTextField('Languages', (val) => _formData.languages = val ?? '', initialValue: _formData.languages),
                    _buildTextField('Hobbies', (val) => _formData.hobbies = val ?? '', initialValue: _formData.hobbies),
                    _buildTextField('Certifications', (val) => _formData.certifications = val ?? '', initialValue: _formData.certifications, maxLines: 2),
                    _buildTextField('Awards', (val) => _formData.awards = val ?? '', initialValue: _formData.awards, maxLines: 2),
                    _buildTextField('References', (val) => _formData.references = val ?? '', initialValue: _formData.references, maxLines: 2),
                    _buildTextField('Career Objective', (val) => _formData.objective = val ?? '', initialValue: _formData.objective, maxLines: 3),
                    _buildTextField('Professional Summary', (val) => _formData.summary = val ?? '', initialValue: _formData.summary, maxLines: 3),

                    const SizedBox(height: 24),

                    // Template Selector
                    _buildSectionTitle('🎨 Choose CV Templates'),
                    Text(
                      '${_selectedTemplates.length} template(s) selected',
                      style: const TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _selectedTemplates = List.generate(20, (index) => index + 1);
                            });
                          },
                          child: const Text('Select All'),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _selectedTemplates.clear();
                            });
                          },
                          child: const Text('Clear All'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: CVService.templates.map((template) {
                        final isSelected = _selectedTemplates.contains(template.id);
                        return FilterChip(
                          label: Text(template.name),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _selectedTemplates.add(template.id);
                              } else {
                                _selectedTemplates.remove(template.id);
                              }
                            });
                          },
                          backgroundColor: Colors.grey[200],
                          selectedColor: Colors.purple[100],
                        );
                      }).toList(),
                    ),

                    const SizedBox(height: 32),

                    // Generate Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _generateCV,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.purple,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text(
                          'Generate CV',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.purple,
        ),
      ),
    );
  }

  Widget _buildTextField(
    String label,
    Function(String?) onSaved, {
    bool required = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? initialValue,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: TextFormField(
        initialValue: initialValue,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: Colors.grey[50],
        ),
        maxLines: maxLines,
        keyboardType: keyboardType,
        validator: required
            ? (value) {
                if (value == null || value.isEmpty) {
                  return '$label is required';
                }
                return null;
              }
            : null,
        onSaved: onSaved,
      ),
    );
  }

  Widget _buildResultsView() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Generated CVs'),
        backgroundColor: Colors.purple,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _reset,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Colors.purple, Colors.blue],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text(
                    '✅ Your CVs are Ready!',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_generatedCVs!.length} CV templates generated in PDF and DOCX formats',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('Create New CV'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.purple,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // CV List - using ListView instead of GridView to avoid overflow
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _generatedCVs!.length,
              itemBuilder: (context, index) {
                final cv = _generatedCVs![index];
                final templateColors = [
                  Colors.blue, Colors.green, Colors.purple, Colors.red,
                  Colors.orange, Colors.teal, Colors.blueGrey, Colors.deepOrange,
                  Colors.cyan, Colors.indigo, Colors.deepOrange, Colors.grey,
                  Colors.red, Colors.teal, Colors.purple, Colors.blueGrey,
                  Colors.amber, Colors.green, Colors.purple, Colors.blue,
                ];
                final color = templateColors[(cv.templateId - 1) % templateColors.length];
                return Card(
                  elevation: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Colored header strip
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.1),
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                          border: Border(left: BorderSide(color: color, width: 4)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.description, color: color, size: 22),
                                const SizedBox(width: 8),
                                Text(
                                  'Template ${cv.templateId}',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: color,
                                  ),
                                ),
                              ],
                            ),
                            Chip(
                              label: Text(cv.templateName, style: const TextStyle(fontSize: 12)),
                              backgroundColor: color.withOpacity(0.15),
                              labelStyle: TextStyle(color: color, fontWeight: FontWeight.w600),
                              padding: EdgeInsets.zero,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // PDF section
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.red[50],
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.red[200]!),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.picture_as_pdf, color: Colors.red[600], size: 14),
                                  const SizedBox(width: 4),
                                  Text('PDF', style: TextStyle(color: Colors.red[600], fontWeight: FontWeight.bold, fontSize: 12)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => _launchUrl(cv.pdf.viewUrl),
                                    icon: const Icon(Icons.visibility, size: 15),
                                    label: const Text('View', style: TextStyle(fontSize: 13)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.blue,
                                      side: const BorderSide(color: Colors.blue),
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () => _launchUrl(cv.pdf.downloadUrl),
                                    icon: const Icon(Icons.download, size: 15),
                                    label: const Text('Download', style: TextStyle(fontSize: 13)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.blue,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // DOCX section
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.blue[50],
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.blue[200]!),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.article, color: Colors.blue[600], size: 14),
                                  const SizedBox(width: 4),
                                  Text('DOCX', style: TextStyle(color: Colors.blue[600], fontWeight: FontWeight.bold, fontSize: 12)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () => _launchUrl(cv.docx.viewUrl),
                                    icon: const Icon(Icons.visibility, size: 15),
                                    label: const Text('View', style: TextStyle(fontSize: 13)),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.green,
                                      side: const BorderSide(color: Colors.green),
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () => _launchUrl(cv.docx.downloadUrl),
                                    icon: const Icon(Icons.download, size: 15),
                                    label: const Text('Download', style: TextStyle(fontSize: 13)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 8),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 24),

            // Footer tip
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lightbulb, color: Colors.blue),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Tip: Try different templates to find the one that best suits your style!',
                      style: TextStyle(color: Colors.blue),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
