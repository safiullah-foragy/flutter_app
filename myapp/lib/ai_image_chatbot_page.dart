import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

class AIImageChatbotPage extends StatefulWidget {
  const AIImageChatbotPage({super.key});

  @override
  State<AIImageChatbotPage> createState() => _AIImageChatbotPageState();
}

class _AIImageChatbotPageState extends State<AIImageChatbotPage> {
  final ImagePicker _picker = ImagePicker();
  final List<ChatMessage> _messages = [];
  final ScrollController _scrollController = ScrollController();
  File? _selectedImage;
  Uint8List? _webImage;
  bool _isProcessing = false;
  
  // TODO: Replace with your Render.com URL after deployment
  static const String serverUrl = 'https://your-app-name.onrender.com/predict';

  @override
  void initState() {
    super.initState();
    _messages.add(ChatMessage(
      text: "Hello! I'm your AI Image Recognition Assistant 🤖\n\nI was trained on 1.2 million images and can recognize 1000+ objects including animals, vehicles, food, electronics, and more!\n\nUpload an image and I'll identify what's in it! 📸",
      isUser: false,
      timestamp: DateTime.now(),
    ));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
        
        _messages.add(ChatMessage(
          text: "Analyzing this image...",
          isUser: true,
          timestamp: DateTime.now(),
          imageFile: _selectedImage,
          imageBytes: _webImage,
        ));
        _scrollToBottom();
        
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
        
        _messages.add(ChatMessage(
          text: "Analyzing this photo...",
          isUser: true,
          timestamp: DateTime.now(),
          imageFile: _selectedImage,
          imageBytes: _webImage,
        ));
        _scrollToBottom();
        
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
        const Duration(seconds: 60),
        onTimeout: () {
          throw TimeoutException('The AI server is taking too long. It might be starting up (first request takes 30-60s on free tier). Please try again!');
        },
      );
      
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final predictions = data['predictions'] as List;
        
        if (predictions.isEmpty) {
          _addBotMessage("Hmm, I couldn't identify any clear objects in this image. Try uploading a different image with clearer objects! 🤔");
        } else {
          String resultText = "I can see these objects:\n\n";
          for (int i = 0; i < predictions.length; i++) {
            final pred = predictions[i];
            final emoji = _getEmojiForObject(pred['object']);
            resultText += "${emoji} ${pred['object']}\n   ${pred['confidence']}% confident\n\n";
          }
          resultText += "Trained on 1.2M images from ImageNet! 🎓";
          _addBotMessage(resultText);
        }
      } else if (response.statusCode == 503) {
        _showError('Server is starting up. On free tier, first request takes 30-60 seconds. Please wait and try again!');
      } else {
        _showError('Server error: ${response.statusCode}. Please ensure the server is deployed on Render.');
      }
    } on TimeoutException catch (e) {
      _showError(e.message ?? 'Request timed out');
    } catch (e) {
      _showError('Failed to connect: $e\n\nMake sure you:\n1. Deployed the server on Render\n2. Updated the serverUrl in the code');
    } finally {
      setState(() {
        _isProcessing = false;
        _selectedImage = null;
        _webImage = null;
      });
    }
  }

  String _getEmojiForObject(String objectName) {
    final name = objectName.toLowerCase();
    if (name.contains('dog')) return '🐕';
    if (name.contains('cat')) return '🐈';
    if (name.contains('bird')) return '🐦';
    if (name.contains('car') || name.contains('vehicle')) return '🚗';
    if (name.contains('food') || name.contains('fruit')) return '🍎';
    if (name.contains('flower') || name.contains('plant')) return '🌸';
    if (name.contains('phone') || name.contains('computer')) return '📱';
    if (name.contains('person') || name.contains('human')) return '👤';
    if (name.contains('ball')) return '⚽';
    if (name.contains('book')) return '📚';
    return '🔍';
  }

  void _addBotMessage(String text) {
    setState(() {
      _messages.add(ChatMessage(
        text: text,
        isUser: false,
        timestamp: DateTime.now(),
      ));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Image Recognition'),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: 'About',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('About This AI'),
                  content: const SingleChildScrollView(
                    child: Text(
                      'Model: MobileNetV2\n\n'
                      'Training: ImageNet dataset\n'
                      '• 1.2 million images\n'
                      '• 1000 object categories\n\n'
                      'Can recognize:\n'
                      '• Animals (dogs, cats, birds, etc.)\n'
                      '• Vehicles (cars, bikes, planes)\n'
                      '• Food (fruits, dishes, drinks)\n'
                      '• Electronics\n'
                      '• Furniture\n'
                      '• Nature scenes\n'
                      '• And 900+ more!\n\n'
                      'Accuracy: ~72% top-1\n'
                      'Memory: ~150MB\n'
                      'Inference: <1 second',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return _buildMessageBubble(message);
              },
            ),
          ),
          
          if (_isProcessing)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                border: Border(top: BorderSide(color: Colors.grey[300]!)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('AI is analyzing your image...', style: TextStyle(fontSize: 14)),
                ],
              ),
            ),
          
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.2),
                  spreadRadius: 1,
                  blurRadius: 5,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.photo_library, color: Colors.blue, size: 28),
                  onPressed: _isProcessing ? null : _pickImage,
                  tooltip: 'Pick from gallery',
                ),
                IconButton(
                  icon: const Icon(Icons.camera_alt, color: Colors.blue, size: 28),
                  onPressed: _isProcessing ? null : _takePhoto,
                  tooltip: 'Take photo',
                ),
                const Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'Upload an image to identify objects',
                      style: TextStyle(color: Colors.grey, fontSize: 14),
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
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: message.isUser ? Colors.blue : Colors.grey[200],
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            
            Text(
              message.text,
              style: TextStyle(
                color: message.isUser ? Colors.white : Colors.black87,
                fontSize: 14,
              ),
            ),
            
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
