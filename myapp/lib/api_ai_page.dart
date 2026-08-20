import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'theme_controller.dart';

class ChatMessage {
  final int id;
  final String role; // 'user' | 'assistant'
  final String content;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
  });
}

class ApiAiPage extends StatefulWidget {
  const ApiAiPage({super.key});

  @override
  State<ApiAiPage> createState() => _ApiAiPageState();
}

class _ApiAiPageState extends State<ApiAiPage> {
  // Direct AI API Keys (Set via environment or settings)
  static const String defaultApiKey = String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
  String _currentApiKey = defaultApiKey;

  // Backend URLs for File Extraction
  final String unifiedBaseUrl = 'https://unified-backend-for-connectifyapp.onrender.com/api';
  final String directAiUrl = 'https://image-video-audio-pdf-docs-reader-api-1.onrender.com';

  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  // Chat messages
  final List<ChatMessage> _messages = [
    ChatMessage(
      id: 1,
      role: 'assistant',
      content: "Hello! I'm your Connectify AI Assistant. Upload a file, share a URL, or ask me anything!",
    ),
  ];

  bool _loading = false;

  // File / URL handling
  File? _selectedFile;
  Uint8List? _webFileBytes;
  String? _selectedFileName;
  bool _showUrlInput = false;

  // Context for follow-up questions
  String? _contextForChat;

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    final savedKey = prefs.getString('custom_ai_api_key');
    if (savedKey != null && savedKey.trim().isNotEmpty) {
      setState(() {
        _currentApiKey = savedKey.trim();
      });
    }
  }

  Future<void> _saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_ai_api_key', key.trim());
    setState(() {
      _currentApiKey = key.trim().isNotEmpty ? key.trim() : defaultApiKey;
    });
    _showToast('AI API Key updated successfully');
  }

  @override
  void dispose() {
    _inputController.dispose();
    _urlController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Unified Direct AI Query Handler (Supports Gemini & OpenAI)
  Future<String> _queryAI({
    required String userPrompt,
    String? systemPrompt,
  }) async {
    final key = _currentApiKey.trim();
    if (key.isEmpty) {
      throw Exception('API Key is not configured.');
    }

    // A: Google Gemini / AI Studio Key (starts with 'AQ.' or 'AIza')
    if (key.startsWith('AQ.') || key.startsWith('AIza') || !key.startsWith('sk-')) {
      final combinedPrompt = systemPrompt != null && systemPrompt.isNotEmpty
          ? "$systemPrompt\n\nUser Question:\n$userPrompt"
          : userPrompt;

      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent?key=$key',
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'contents': [
            {
              'parts': [
                {'text': combinedPrompt}
              ]
            }
          ],
          'generationConfig': {
            'temperature': 0.7,
          }
        }),
      ).timeout(const Duration(seconds: 45));

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        final candidates = data['candidates'] as List?;
        if (candidates != null && candidates.isNotEmpty) {
          final parts = candidates[0]['content']?['parts'] as List?;
          if (parts != null && parts.isNotEmpty) {
            final textPart = parts.firstWhere(
              (p) => p['text'] != null && (p['thought'] == null || p['thought'] == false),
              orElse: () => parts.last,
            );
            return textPart['text']?.toString().trim() ?? 'No text generated.';
          }
        }
        return 'No response generated.';
      } else {
        final errorData = json.decode(utf8.decode(response.bodyBytes));
        final msg = errorData['error']?['message'] ?? 'HTTP ${response.statusCode}';
        throw Exception('Gemini Error: $msg');
      }
    }

    // B: OpenAI Key (starts with 'sk-')
    final messages = <Map<String, String>>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }
    messages.add({'role': 'user', 'content': userPrompt});

    final response = await http.post(
      Uri.parse('https://api.openai.com/v1/chat/completions'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $key',
      },
      body: json.encode({
        'model': 'gpt-4o-mini',
        'messages': messages,
        'temperature': 0.7,
      }),
    ).timeout(const Duration(seconds: 45));

    if (response.statusCode == 200) {
      final data = json.decode(utf8.decode(response.bodyBytes));
      final choices = data['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        return choices[0]['message']['content']?.toString().trim() ?? 'No response content.';
      }
      return 'No response choices returned.';
    } else {
      final errorData = json.decode(utf8.decode(response.bodyBytes));
      final errorObj = errorData['error'] as Map<String, dynamic>?;
      final errorCode = errorObj?['code'] ?? '';
      final errorMsg = errorObj?['message'] ?? 'HTTP ${response.statusCode}';
      throw Exception('OpenAI Error ($errorCode): $errorMsg');
    }
  }

  // Get Auth headers matching connectify_web apiClient (Bearer token)
  Future<Map<String, String>> _getAuthHeaders() async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final token = await user.getIdToken();
        if (token != null) {
          headers['Authorization'] = 'Bearer $token';
        }
      }
    } catch (_) {}
    return headers;
  }

  // File Picker
  Future<void> _handleFileSelect() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp',
          'mp4', 'avi', 'mov', 'mkv', 'webm',
          'mp3', 'wav', 'aac', 'm4a', 'ogg',
          'pdf', 'doc', 'docx', 'txt',
        ],
      );

      if (result != null) {
        setState(() {
          if (kIsWeb) {
            _webFileBytes = result.files.single.bytes;
          } else {
            _selectedFile = File(result.files.single.path!);
          }
          _selectedFileName = result.files.single.name;
          _showUrlInput = false;
          _urlController.clear();
        });
      }
    } catch (e) {
      _showToast('Error picking file: $e', isError: true);
    }
  }

  // Send handler (Direct AI + Conversation Context)
  Future<void> _handleSend() async {
    // 1. Handle file or URL analysis if selected
    if (_selectedFile != null || _webFileBytes != null || _urlController.text.trim().isNotEmpty) {
      await _handleAnalyze();
      return;
    }

    // 2. Handle regular chat message
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final userMessage = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch,
      role: 'user',
      content: text,
    );

    setState(() {
      _messages.add(userMessage);
      _inputController.clear();
      _loading = true;
    });

    _scrollToBottom();

    String aiResponse = '';

    // Step A: Direct AI API Query
    try {
      String sysPrompt = "You are a helpful, knowledgeable, and polite AI Assistant in the Connectify social app.";
      if (_contextForChat != null && _contextForChat!.isNotEmpty) {
        sysPrompt += "\n\nUploaded Content Context:\n\"\"\"${_contextForChat!}\"\"\"\nUse this context to accurately answer any user questions.";
      }
      aiResponse = await _queryAI(userPrompt: text, systemPrompt: sysPrompt);
    } catch (directAiError) {
      debugPrint('Direct AI error: $directAiError');

      // Step B: Backend Fallback
      try {
        final headers = await _getAuthHeaders();
        final response = await http.post(
          Uri.parse('$unifiedBaseUrl/ai/chat'),
          headers: headers,
          body: json.encode({
            'message': text,
            'context': _contextForChat,
          }),
        ).timeout(const Duration(seconds: 20));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          if (data['success'] == true || data['response'] != null) {
            final raw = (data['response'] ?? data['reply'] ?? '').toString();
            if (!raw.contains('404') && !raw.contains('model_not_found')) {
              aiResponse = raw;
            }
          }
        }
      } catch (_) {}

      // Step C: If still empty, display clean smart response
      if (aiResponse.isEmpty) {
        aiResponse = _buildChatFallback(text, _contextForChat);
      }
    }

    setState(() {
      _messages.add(
        ChatMessage(
          id: DateTime.now().millisecondsSinceEpoch + 1,
          role: 'assistant',
          content: aiResponse,
        ),
      );
    });

    setState(() => _loading = false);
    _scrollToBottom();
  }

  // Analyze file or URL (Extract text via backend -> Directly analyze with Gemini/OpenAI)
  Future<void> _handleAnalyze() async {
    final fileName = _selectedFileName;
    final url = _urlController.text.trim();

    if (_selectedFile == null && _webFileBytes == null && url.isEmpty) {
      _showToast('Please select a file or enter a URL', isError: true);
      return;
    }

    final userMessage = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch,
      role: 'user',
      content: fileName != null ? '📎 Analyzing file: $fileName' : '🔗 Analyzing URL: $url',
    );

    setState(() {
      _messages.add(userMessage);
      _loading = true;
    });

    _scrollToBottom();

    try {
      Map<String, dynamic>? extractData;
      final authHeaders = await _getAuthHeaders();

      // Step 1: Extract content from file / URL
      try {
        if (url.isNotEmpty) {
          final res = await http.post(
            Uri.parse('$unifiedBaseUrl/ai/extract'),
            headers: authHeaders,
            body: json.encode({'url': url}),
          ).timeout(const Duration(seconds: 45));
          if (res.statusCode == 200) extractData = json.decode(res.body);
        } else {
          final req = http.MultipartRequest('POST', Uri.parse('$unifiedBaseUrl/ai/extract'));
          if (authHeaders.containsKey('Authorization')) {
            req.headers['Authorization'] = authHeaders['Authorization']!;
          }
          if (kIsWeb && _webFileBytes != null) {
            req.files.add(http.MultipartFile.fromBytes('file', _webFileBytes!, filename: fileName ?? 'file'));
          } else if (_selectedFile != null) {
            req.files.add(await http.MultipartFile.fromPath('file', _selectedFile!.path));
          }
          final streamed = await req.send().timeout(const Duration(seconds: 45));
          final res = await http.Response.fromStream(streamed);
          if (res.statusCode == 200) extractData = json.decode(res.body);
        }
      } catch (_) {}

      // Fallback extraction
      if (extractData == null) {
        if (url.isNotEmpty) {
          final res = await http.post(
            Uri.parse('$directAiUrl/api/extract'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'url': url}),
          ).timeout(const Duration(seconds: 45));
          if (res.statusCode == 200) extractData = json.decode(res.body);
        } else {
          final req = http.MultipartRequest('POST', Uri.parse('$directAiUrl/api/extract'));
          if (kIsWeb && _webFileBytes != null) {
            req.files.add(http.MultipartFile.fromBytes('file', _webFileBytes!, filename: fileName ?? 'file'));
          } else if (_selectedFile != null) {
            req.files.add(await http.MultipartFile.fromPath('file', _selectedFile!.path));
          }
          final streamed = await req.send().timeout(const Duration(seconds: 45));
          final res = await http.Response.fromStream(streamed);
          if (res.statusCode == 200) extractData = json.decode(res.body);
        }
      }

      final extractedText = (extractData?['extractedText'] as String?) ?? '';
      _contextForChat = extractedText;

      String responseContent = '';

      // Step 2: Directly Query AI with the extracted content!
      if (extractedText.isNotEmpty) {
        try {
          final analysisPrompt = """
Please analyze the following extracted document/media content and provide a comprehensive structured breakdown:

\"\"\"
$extractedText
\"\"\"

Format your response cleanly with these exact sections:
📊 **AI Analysis:**
(Detailed explanation and breakdown of the document/image content, key details, and context)

📝 **Summary:**
(Clear executive summary)

🔑 **Key Points:**
• (Key point 1)
• (Key point 2)
• (Key point 3)
""";
          responseContent = await _queryAI(userPrompt: analysisPrompt);
        } catch (directAiErr) {
          debugPrint('Direct AI analysis error: $directAiErr');
        }
      }

      // Step 3: Fallback formatting if direct AI had issues
      if (responseContent.isEmpty) {
        final rawExplanation = (extractData?['aiExplanation'] as String?) ?? '';
        final isAiError = rawExplanation.contains('unavailable') ||
            rawExplanation.contains('404') ||
            rawExplanation.contains('model_not_found');

        if (!isAiError && rawExplanation.isNotEmpty) {
          responseContent += '📊 **AI Analysis:**\n$rawExplanation\n\n';
        }

        if (extractData?['summary'] != null && (extractData!['summary'] as String).isNotEmpty) {
          final summary = extractData['summary'] as String;
          if (!summary.contains('Unable to generate') && !summary.contains('404')) {
            responseContent += '📝 **Summary:**\n$summary\n\n';
          }
        }

        if (extractData?['keyPoints'] != null && extractData!['keyPoints'] is List) {
          final List<dynamic> points = extractData['keyPoints'];
          if (points.isNotEmpty) {
            responseContent += '🔑 **Key Points:**\n${points.map((p) => '• $p').join('\n')}\n\n';
          }
        }

        if (extractedText.isNotEmpty) {
          final preview = extractedText.length > 600 ? extractedText.substring(0, 600) : extractedText;
          responseContent += '📄 **Extracted Text (preview):**\n$preview${extractedText.length > 600 ? '...' : ''}';
        }
      }

      if (responseContent.trim().isEmpty) {
        responseContent = 'Content analyzed, but no data was extracted. Please try a different file or URL.';
      }

      setState(() {
        _messages.add(
          ChatMessage(
            id: DateTime.now().millisecondsSinceEpoch + 1,
            role: 'assistant',
            content: responseContent.trim(),
          ),
        );

        _selectedFile = null;
        _webFileBytes = null;
        _selectedFileName = null;
        _urlController.clear();
        _showUrlInput = false;
      });

      _showToast('Analysis complete! You can now ask questions about this content.');
    } catch (error) {
      String errorMsg = 'Failed to analyze content. $error';
      setState(() {
        _messages.add(
          ChatMessage(
            id: DateTime.now().millisecondsSinceEpoch + 1,
            role: 'assistant',
            content: errorMsg,
          ),
        );
      });
      _showToast('Failed to analyze', isError: true);
    } finally {
      setState(() => _loading = false);
      _scrollToBottom();
    }
  }

  String _buildChatFallback(String text, String? context) {
    final lower = text.trim().toLowerCase();
    if (RegExp(r'^(hi|hello|hey|greetings|hola)\b').hasMatch(lower)) {
      if (context != null && context.isNotEmpty) {
        return "Hello! I'm ready to answer questions about your uploaded content. What would you like to know?";
      }
      return "Hello! I'm your AI Assistant. How can I help you today?";
    }

    if (context != null && context.isNotEmpty) {
      final lines = context.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).take(5).toList();
      return "Based on your uploaded content, here is the relevant text:\n\n" +
          lines.map((l) => "• $l").join("\n") +
          "\n\nFeel free to ask more specific questions!";
    }

    return "I received your message: \"$text\". Upload a file or share a URL to analyze documents, images, and media!";
  }

  void _showApiKeyDialog() {
    final controller = TextEditingController(text: _currentApiKey);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.key_rounded, color: Color(0xFF9333EA)),
            SizedBox(width: 8),
            Text('AI API Key Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your Google Gemini or OpenAI API Key for direct high-speed AI analysis:',
              style: TextStyle(fontSize: 13, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 2,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'AQ... or AIza... (Gemini) / sk-... (OpenAI)',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.all(10),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Supports: Gemini Flash / Pro / Gemma & OpenAI GPT-4o-mini',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _saveApiKey(defaultApiKey);
              Navigator.pop(ctx);
            },
            child: const Text('Reset Default'),
          ),
          ElevatedButton(
            onPressed: () {
              _saveApiKey(controller.text);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF9333EA)),
            child: const Text('Save Key', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showToast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade700 : Colors.green.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final theme = ThemeController.instance;

    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        flexibleSpace: Container(
          decoration: BoxDecoration(gradient: theme.appBarGradient),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 1,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.smart_toy_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI Assistant',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Gemini Flash & GPT-4o Direct Engine',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'AI API Key Settings',
            icon: const Icon(Icons.key_rounded, color: Colors.white),
            onPressed: _showApiKeyDialog,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Messages List
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                itemCount: _messages.length + (_loading ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == _messages.length && _loading) {
                    return _buildLoadingBubble();
                  }

                  final message = _messages[index];
                  final isUser = message.role == 'user';

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Row(
                      mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isUser) ...[
                          Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                              color: Color(0xFFF3E8FF),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.smart_toy_rounded, color: Color(0xFF9333EA), size: 20),
                          ),
                          const SizedBox(width: 10),
                        ],
                        Flexible(
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.78,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: isUser ? theme.primaryColor : Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: isUser ? null : Border.all(color: Colors.grey.shade200),
                              boxShadow: isUser
                                  ? [
                                      BoxShadow(
                                        color: theme.primaryColor.withValues(alpha: 0.25),
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                    ]
                                  : [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.04),
                                        blurRadius: 6,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                            ),
                            child: SelectableText(
                              message.content,
                              style: TextStyle(
                                color: isUser ? Colors.white : const Color(0xFF111827),
                                fontSize: 14,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ),
                        if (isUser) ...[
                          const SizedBox(width: 10),
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: theme.primaryColor.withValues(alpha: 0.15),
                            backgroundImage: user?.photoURL != null
                                ? CachedNetworkImageProvider(user!.photoURL!)
                                : null,
                            child: user?.photoURL == null
                                ? Icon(Icons.person, color: theme.primaryColor, size: 20)
                                : null,
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),

            // Bottom Input Area
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // File Preview (Green banner)
                  if (_selectedFileName != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0FDF4),
                        border: Border.all(color: const Color(0xFFBBF7D0)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.description_rounded, color: Color(0xFF16A34A), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _selectedFileName!,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111827)),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedFile = null;
                                _webFileBytes = null;
                                _selectedFileName = null;
                              });
                            },
                            child: const Icon(Icons.close, color: Colors.grey, size: 18),
                          ),
                        ],
                      ),
                    ),

                  // URL Input (Blue banner)
                  if (_showUrlInput)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        border: Border.all(color: const Color(0xFFBFDBFE)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.link_rounded, color: Color(0xFF2563EB), size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _urlController,
                              keyboardType: TextInputType.url,
                              decoration: const InputDecoration(
                                hintText: 'Enter URL (https://example.com/file.pdf)',
                                hintStyle: TextStyle(fontSize: 13, color: Colors.grey),
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _showUrlInput = false;
                                _urlController.clear();
                              });
                            },
                            child: const Icon(Icons.close, color: Colors.grey, size: 18),
                          ),
                        ],
                      ),
                    ),

                  // Input Row
                  Row(
                    children: [
                      // Paperclip (File Upload)
                      IconButton(
                        icon: const Icon(Icons.attach_file_rounded, color: Color(0xFF4B5563)),
                        tooltip: 'Upload file',
                        onPressed: _loading || _showUrlInput ? null : _handleFileSelect,
                      ),

                      // Link Button
                      IconButton(
                        icon: const Icon(Icons.link_rounded, color: Color(0xFF4B5563)),
                        tooltip: 'Add URL',
                        onPressed: _loading || _selectedFileName != null
                            ? null
                            : () {
                                setState(() {
                                  _showUrlInput = !_showUrlInput;
                                  if (!_showUrlInput) _urlController.clear();
                                });
                              },
                      ),

                      // Text Input
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: (_selectedFileName != null || _showUrlInput)
                                ? Colors.grey.shade100
                                : Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: TextField(
                            controller: _inputController,
                            focusNode: _inputFocusNode,
                            enabled: !_loading && _selectedFileName == null && !_showUrlInput,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _handleSend(),
                            decoration: InputDecoration(
                              hintText: (_selectedFileName != null || _urlController.text.isNotEmpty)
                                  ? 'Click send to analyze with AI...'
                                  : 'Type a message or upload content...',
                              hintStyle: const TextStyle(fontSize: 13.5, color: Colors.grey),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // Send Button
                      Container(
                        decoration: BoxDecoration(
                          color: theme.primaryColor,
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: _loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                )
                              : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                          onPressed: _loading ? null : _handleSend,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingBubble() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: Color(0xFFF3E8FF),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.smart_toy_rounded, color: Color(0xFF9333EA), size: 20),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.grey.shade200),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF9333EA)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
