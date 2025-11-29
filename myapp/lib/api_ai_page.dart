import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:typed_data';

class ApiAiPage extends StatefulWidget {
  const ApiAiPage({Key? key}) : super(key: key);

  @override
  State<ApiAiPage> createState() => _ApiAiPageState();
}

class _ApiAiPageState extends State<ApiAiPage> {
  final String apiBaseUrl = 'https://image-video-audio-pdf-docs-reader-api-1.onrender.com';
  
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  File? _selectedFile;
  Uint8List? _webFileBytes;
  String? _fileName;
  bool _isLoading = false;
  bool _isChatMode = false;
  
  String? _extractedText;
  String? _aiExplanation;
  String? _summary;
  List<String>? _keyPoints;
  
  List<Map<String, String>> _chatMessages = [];
  String? _contextForChat;

  @override
  void dispose() {
    _urlController.dispose();
    _chatController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Pick file from device
  Future<void> _pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 
                           'mp4', 'avi', 'mov', 'mkv', 'webm',
                           'mp3', 'wav', 'aac', 'm4a', 'ogg',
                           'pdf', 'doc', 'docx', 'txt'],
      );

      if (result != null) {
        setState(() {
          if (kIsWeb) {
            _webFileBytes = result.files.single.bytes;
          } else {
            _selectedFile = File(result.files.single.path!);
          }
          _fileName = result.files.single.name;
          _clearResults();
        });
      }
    } catch (e) {
      _showError('Error picking file: $e');
    }
  }

  // Pick image from camera
  Future<void> _pickImageFromCamera() async {
    if (kIsWeb) {
      _showError('Camera not available on web. Please use file picker.');
      return;
    }
    
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.camera);

      if (image != null) {
        setState(() {
          _selectedFile = File(image.path);
          _fileName = image.name;
          _clearResults();
        });
      }
    } catch (e) {
      _showError('Error taking photo: $e');
    }
  }

  // Pick video from camera
  Future<void> _pickVideoFromCamera() async {
    if (kIsWeb) {
      _showError('Video recording not available on web. Please use file picker.');
      return;
    }
    
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? video = await picker.pickVideo(source: ImageSource.camera);

      if (video != null) {
        setState(() {
          _selectedFile = File(video.path);
          _fileName = video.name;
          _clearResults();
        });
      }
    } catch (e) {
      _showError('Error recording video: $e');
    }
  }

  // Upload file and get AI analysis
  Future<void> _uploadFile() async {
    if (_selectedFile == null && _webFileBytes == null) {
      _showError('Please select a file first');
      return;
    }

    setState(() {
      _isLoading = true;
      _clearResults();
    });

    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$apiBaseUrl/api/extract'),
      );

      if (kIsWeb && _webFileBytes != null) {
        request.files.add(
          http.MultipartFile.fromBytes(
            'file',
            _webFileBytes!,
            filename: _fileName ?? 'file',
          ),
        );
      } else if (_selectedFile != null) {
        request.files.add(
          await http.MultipartFile.fromPath('file', _selectedFile!.path),
        );
      }

      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        
        // Check if AI analysis failed
        String aiExplanation = data['aiExplanation'] ?? '';
        if (aiExplanation.contains('unavailable') || aiExplanation.contains('API key')) {
          _showError('⚠️ OpenAI API not configured.\n\nExtracted text: ${(data['extractedText'] ?? '').substring(0, 100)}...\n\nTo get AI analysis, configure OPENAI_API_KEY on Render.com');
        }
        
        setState(() {
          _extractedText = data['extractedText'];
          _aiExplanation = aiExplanation;
          _summary = data['summary'];
          _keyPoints = List<String>.from(data['keyPoints'] ?? []);
          _contextForChat = _extractedText;
          _isLoading = false;
        });
        
        if (!aiExplanation.contains('unavailable')) {
          _showSuccess('File analyzed successfully!');
        }
      } else {
        var error = json.decode(response.body);
        String errorMsg = error['error'] ?? 'Failed to analyze file';
        if (errorMsg.contains('API key')) {
          _showError('⚠️ Server configuration needed\n\nPlease add OPENAI_API_KEY to Render.com environment variables');
        } else {
          _showError(errorMsg);
        }
        setState(() => _isLoading = false);
      }
    } catch (e) {
      _showError('Error uploading file: $e');
      setState(() => _isLoading = false);
    }
  }

  // Process URL
  Future<void> _processUrl() async {
    if (_urlController.text.trim().isEmpty) {
      _showError('Please enter a URL');
      return;
    }

    setState(() {
      _isLoading = true;
      _clearResults();
    });

    try {
      var response = await http.post(
        Uri.parse('$apiBaseUrl/api/extract'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'url': _urlController.text.trim()}),
      );

      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        
        // Check if AI analysis failed
        String aiExplanation = data['aiExplanation'] ?? '';
        if (aiExplanation.contains('unavailable') || aiExplanation.contains('API key')) {
          _showError('⚠️ OpenAI API not configured.\n\nExtracted text: ${(data['extractedText'] ?? '').substring(0, 100)}...\n\nTo get AI analysis, configure OPENAI_API_KEY on Render.com');
        }
        
        setState(() {
          _extractedText = data['extractedText'];
          _aiExplanation = aiExplanation;
          _summary = data['summary'];
          _keyPoints = List<String>.from(data['keyPoints'] ?? []);
          _contextForChat = _extractedText;
          _isLoading = false;
        });
        
        if (!aiExplanation.contains('unavailable')) {
          _showSuccess('URL processed successfully!');
        }
      } else {
        var error = json.decode(response.body);
        String errorMsg = error['error'] ?? 'Failed to process URL';
        if (errorMsg.contains('API key')) {
          _showError('⚠️ Server configuration needed\n\nPlease add OPENAI_API_KEY to Render.com environment variables');
        } else {
          _showError(errorMsg);
        }
        setState(() => _isLoading = false);
      }
    } catch (e) {
      _showError('Error processing URL: $e');
      setState(() => _isLoading = false);
    }
  }

  // Chat with AI using context
  Future<void> _sendChatMessage() async {
    if (_chatController.text.trim().isEmpty) return;
    
    if (_contextForChat == null) {
      _showError('Please analyze a file or URL first to enable chat');
      return;
    }

    String userMessage = _chatController.text.trim();
    
    setState(() {
      _chatMessages.add({'role': 'user', 'content': userMessage});
      _chatController.clear();
    });

    _scrollToBottom();

    try {
      // Call the chat endpoint with message and context
      var response = await http.post(
        Uri.parse('$apiBaseUrl/api/chat'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'message': userMessage,
          'context': _contextForChat
        }),
      );

      if (response.statusCode == 200) {
        var data = json.decode(response.body);
        
        if (data['success'] == true) {
          String aiResponse = data['response'] ?? 'No response received';
          
          setState(() {
            _chatMessages.add({'role': 'assistant', 'content': aiResponse});
          });
          _scrollToBottom();
        } else {
          String errorMsg = data['error'] ?? 'Failed to get AI response';
          if (errorMsg.contains('API key')) {
            _showError('OpenAI API key not configured on server. Please configure OPENAI_API_KEY in Render.com environment variables.');
          } else {
            _showError(errorMsg);
          }
        }
      } else {
        var errorData = json.decode(response.body);
        String errorMsg = errorData['error'] ?? 'Failed to get AI response';
        if (errorMsg.contains('API key')) {
          _showError('⚠️ OpenAI API key not configured.\n\nPlease add OPENAI_API_KEY to Render.com:\n1. Go to dashboard.render.com\n2. Select your service\n3. Environment → Add OPENAI_API_KEY');
        } else {
          _showError(errorMsg);
        }
      }
    } catch (e) {
      _showError('Error sending message: $e');
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearResults() {
    _extractedText = null;
    _aiExplanation = null;
    _summary = null;
    _keyPoints = null;
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Content Analyzer'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_isChatMode ? Icons.analytics : Icons.chat),
            onPressed: _contextForChat != null
                ? () => setState(() => _isChatMode = !_isChatMode)
                : null,
            tooltip: _isChatMode ? 'View Analysis' : 'Chat Mode',
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.deepPurple, Colors.deepPurple.shade300],
          ),
        ),
        child: SafeArea(
          child: _isChatMode ? _buildChatView() : _buildAnalysisView(),
        ),
      ),
    );
  }

  Widget _buildAnalysisView() {
    return Column(
      children: [
        // Input Section
        Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // File Selection
              if (_selectedFile != null || _webFileBytes != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle, color: Colors.green),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _fileName ?? 'File selected',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => setState(() {
                          _selectedFile = null;
                          _webFileBytes = null;
                          _fileName = null;
                        }),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              
              // File Picker Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _pickFile,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Pick File'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                  if (!kIsWeb) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _pickImageFromCamera,
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Camera'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (!kIsWeb) ...[
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _isLoading ? null : _pickVideoFromCamera,
                  icon: const Icon(Icons.videocam),
                  label: const Text('Record Video'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
              
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
              
              // URL Input
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'Or enter URL',
                  hintText: 'https://example.com/file.pdf',
                  prefixIcon: const Icon(Icons.link),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: Colors.grey.shade50,
                ),
              ),
              const SizedBox(height: 16),
              
              // Analyze Button
              ElevatedButton.icon(
                onPressed: _isLoading
                    ? null
                    : ((_selectedFile != null || _webFileBytes != null) ? _uploadFile : _processUrl),
                icon: _isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(_isLoading ? 'Analyzing...' : 'Analyze with AI'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        
        // Results Section
        Expanded(
          child: _buildResultsSection(),
        ),
      ],
    );
  }

  Widget _buildResultsSection() {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
            const Text(
              'Analyzing content...',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      );
    }

    if (_aiExplanation == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.upload_file, size: 80, color: Colors.white.withOpacity(0.5)),
            const SizedBox(height: 16),
            Text(
              'Upload a file or enter a URL\nto get AI analysis',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.8),
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ListView(
        children: [
          // AI Explanation
          _buildResultCard(
            'AI Explanation',
            _aiExplanation ?? '',
            Icons.psychology,
            Colors.purple,
          ),
          const SizedBox(height: 16),
          
          // Summary
          if (_summary != null && _summary!.isNotEmpty)
            _buildResultCard(
              'Summary',
              _summary!,
              Icons.summarize,
              Colors.blue,
            ),
          if (_summary != null && _summary!.isNotEmpty)
            const SizedBox(height: 16),
          
          // Key Points
          if (_keyPoints != null && _keyPoints!.isNotEmpty)
            _buildKeyPointsCard(),
          if (_keyPoints != null && _keyPoints!.isNotEmpty)
            const SizedBox(height: 16),
          
          // Extracted Text
          if (_extractedText != null && _extractedText!.isNotEmpty)
            _buildResultCard(
              'Extracted Text',
              _extractedText!,
              Icons.text_fields,
              Colors.orange,
            ),
        ],
      ),
    );
  }

  Widget _buildResultCard(String title, String content, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            content,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyPointsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.key, color: Colors.green, size: 24),
              const SizedBox(width: 8),
              const Text(
                'Key Points',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.green,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...(_keyPoints ?? []).map((point) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• ', style: TextStyle(fontSize: 16)),
                    Expanded(
                      child: Text(
                        point,
                        style: const TextStyle(fontSize: 14, height: 1.5),
                      ),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildChatView() {
    return Column(
      children: [
        // Chat Messages
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: _chatMessages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 80,
                          color: Colors.grey.shade300,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Start chatting about the content',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _chatMessages.length,
                    itemBuilder: (context, index) {
                      final message = _chatMessages[index];
                      final isUser = message['role'] == 'user';
                      
                      return Align(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.7,
                          ),
                          decoration: BoxDecoration(
                            color: isUser
                                ? Colors.deepPurple
                                : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            message['content']!,
                            style: TextStyle(
                              color: isUser ? Colors.white : Colors.black87,
                              fontSize: 14,
                              height: 1.4,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
        
        // Chat Input
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
                offset: const Offset(0, -5),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  decoration: InputDecoration(
                    hintText: 'Ask anything about the content...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendChatMessage(),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: Colors.deepPurple,
                child: IconButton(
                  icon: const Icon(Icons.send, color: Colors.white),
                  onPressed: _sendChatMessage,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
