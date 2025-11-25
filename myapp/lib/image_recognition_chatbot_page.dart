import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

class ImageRecognitionChatbotPage extends StatefulWidget {
  const ImageRecognitionChatbotPage({super.key});

  @override
  State<ImageRecognitionChatbotPage> createState() => _ImageRecognitionChatbotPageState();
}

class _ImageRecognitionChatbotPageState extends State<ImageRecognitionChatbotPage> {
  final ImagePicker _picker = ImagePicker();
  final List<ChatMessage> _messages = [];
  File? _selectedImage;
  Uint8List? _webImage;
  bool _isProcessing = false;
  
  // Your Render.com server URL
  static const String serverUrl = 'https://flutter-app-6l0u.onrender.com/predict';

  @override
  void initState() {
    super.initState();
    // Add welcome message
    _messages.add(ChatMessage(
      text: "Hello! I'm your Image Recognition Assistant. Upload an image and I'll identify all the objects in it! 📸",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  Future<void> _pickImage() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        if (kIsWeb) {
          final bytes = await pickedFile.readAsBytes();
          setState(() {
            _webImage = bytes;
            _selectedImage = null;
          });
        } else {
          setState(() {
            _selectedImage = File(pickedFile.path);
            _webImage = null;
          });
        }
        
        // Add user message
        _messages.add(ChatMessage(
          text: "Here's an image to analyze:",
          isUser: true,
          timestamp: DateTime.now(),
          imageFile: _selectedImage,
          imageBytes: _webImage,
        ));
        
        // Process the image
        await _sendImageToServer();
      }
    } catch (e) {
      _showError('Failed to pick image: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? pickedFile = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        if (kIsWeb) {
          final bytes = await pickedFile.readAsBytes();
          setState(() {
            _webImage = bytes;
            _selectedImage = null;
          });
        } else {
          setState(() {
            _selectedImage = File(pickedFile.path);
            _webImage = null;
          });
        }
        
        // Add user message
        _messages.add(ChatMessage(
          text: "Here's a photo to analyze:",
          isUser: true,
          timestamp: DateTime.now(),
          imageFile: _selectedImage,
          imageBytes: _webImage,
        ));
        
        // Process the image
        await _sendImageToServer();
      }
    } catch (e) {
      _showError('Failed to take photo: $e');
    }
  }

  Future<void> _sendImageToServer() async {
    setState(() {
      _isProcessing = true;
    });

    try {
      var request = http.MultipartRequest('POST', Uri.parse(serverUrl));
      
      if (kIsWeb && _webImage != null) {
        request.files.add(http.MultipartFile.fromBytes(
          'image',
          _webImage!,
          filename: 'image.jpg',
        ));
      } else if (_selectedImage != null) {
        request.files.add(await http.MultipartFile.fromPath(
          'image',
          _selectedImage!.path,
        ));
      }

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw TimeoutException('Server took too long to respond');
        },
      );
      
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final predictions = data['predictions'] as List;
        
        if (predictions.isEmpty) {
          _addBotMessage("I couldn't identify any objects in this image. Try a different image with clearer objects!");
        } else {
          String resultText = "I found the following objects:\n\n";
          for (int i = 0; i < predictions.length; i++) {
            final pred = predictions[i];
            resultText += "${i + 1}. ${pred['class']} (${(pred['confidence'] * 100).toStringAsFixed(1)}% confident)\n";
          }
          _addBotMessage(resultText);
        }
      } else {
        _showError('Server error: ${response.statusCode}');
      }
    } catch (e) {
      if (e is TimeoutException) {
        _showError('Server is taking too long. Please try again.');
      } else {
        _showError('Failed to analyze image: $e');
      }
    } finally {
      setState(() {
        _isProcessing = false;
        _selectedImage = null;
        _webImage = null;
      });
    }
  }

  void _addBotMessage(String text) {
    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isUser: false,
        timestamp: DateTime.now(),
      ));
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Image Recognition Bot'),
        backgroundColor: Colors.blue,
      ),
      body: Column(
        children: [
          // Chat messages
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageBubble(message);
              },
            ),
          ),
          
          // Processing indicator
          if (_isProcessing)
            Container(
              padding: const EdgeInsets.all(16),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 16),
                  Text('Analyzing image...'),
                ],
              ),
            ),
          
          // Input area
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.3),
                  spreadRadius: 1,
                  blurRadius: 5,
                  offset: const Offset(0, -3),
                ),
              ],
            ),
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.photo_library, color: Colors.blue),
                  onPressed: _isProcessing ? null : _pickImage,
                  tooltip: 'Pick from gallery',
                ),
                IconButton(
                  icon: const Icon(Icons.camera_alt, color: Colors.blue),
                  onPressed: _isProcessing ? null : _takePhoto,
                  tooltip: 'Take photo',
                ),
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'Upload an image to identify objects',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: message.isUser ? Colors.blue : Colors.grey[300],
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Display image if present
            if (message.imageFile != null && !kIsWeb)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  message.imageFile!,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            if (message.imageBytes != null && kIsWeb)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  message.imageBytes!,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            if (message.imageFile != null || message.imageBytes != null)
              const SizedBox(height: 8),
            
            // Display text
            Text(
              message.text,
              style: TextStyle(
                color: message.isUser ? Colors.white : Colors.black87,
                fontSize: 14,
              ),
            ),
            
            // Timestamp
            const SizedBox(height: 4),
            Text(
              _formatTime(message.timestamp),
              style: TextStyle(
                color: message.isUser ? Colors.white70 : Colors.black54,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final File? imageFile;
  final Uint8List? imageBytes;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.imageFile,
    this.imageBytes,
  });
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  
  @override
  String toString() => message;
}
