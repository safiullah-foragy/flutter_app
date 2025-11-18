import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'download_helper_web.dart' if (dart.library.io) 'download_helper_stub.dart' as download_helper;

class DocumentViewer extends StatefulWidget {
  final String documentUrl;
  final String fileName;
  final String fileType; // 'pdf', 'txt', 'document'

  const DocumentViewer({
    super.key,
    required this.documentUrl,
    required this.fileName,
    required this.fileType,
  });

  @override
  State<DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<DocumentViewer> {
  bool _isLoading = false;
  String? _textContent;
  bool _loadError = false;

  @override
  void initState() {
    super.initState();
    if (widget.fileType == 'txt') {
      _loadTextContent();
    }
  }

  Future<void> _loadTextContent() async {
    setState(() {
      _isLoading = true;
      _loadError = false;
    });

    try {
      final response = await http.get(Uri.parse(widget.documentUrl));
      if (response.statusCode == 200) {
        setState(() {
          _textContent = response.body;
          _isLoading = false;
        });
      } else {
        setState(() {
          _loadError = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading text file: $e');
      setState(() {
        _loadError = true;
        _isLoading = false;
      });
    }
  }

  Future<void> _downloadDocument() async {
    setState(() => _isLoading = true);

    try {
      if (kIsWeb) {
        // Web: Download using helper function
        await download_helper.downloadDocument(widget.documentUrl, widget.fileName);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Downloaded: ${widget.fileName}')),
          );
        }
      } else {
        // Mobile: Open in browser to trigger download
        final uri = Uri.parse(widget.documentUrl);
        final launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
        
        if (launched && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Opening in browser for download...'),
            ),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unable to download. Please install a browser app.'),
              duration: Duration(seconds: 4),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error downloading document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download failed: ${e.toString()}')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _openInBrowser() async {
    try {
      final uri = Uri.parse(widget.documentUrl);
      // Use platformDefault on mobile to open in browser, externalApplication on web
      final mode = kIsWeb ? LaunchMode.externalApplication : LaunchMode.platformDefault;
      final launched = await launchUrl(uri, mode: mode);
      
      if (!launched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to open document. Please install a browser or PDF viewer app.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error opening document: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to open document. Please install a browser or PDF viewer app.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
  }

  IconData _getFileIcon() {
    switch (widget.fileType) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'txt':
        return Icons.text_snippet;
      default:
        return Icons.description;
    }
  }

  String _getFileTypeLabel() {
    switch (widget.fileType) {
      case 'pdf':
        return 'PDF Document';
      case 'txt':
        return 'Text File';
      case 'document':
        return 'Document';
      default:
        return 'Document';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: 'Open in Browser',
            onPressed: _openInBrowser,
          ),
          IconButton(
            icon: _isLoading 
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download),
            tooltip: 'Download',
            onPressed: _isLoading ? null : _downloadDocument,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    // For TXT files, show content directly
    if (widget.fileType == 'txt') {
      if (_isLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_loadError) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text('Failed to load text file'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadTextContent,
                child: const Text('Retry'),
              ),
            ],
          ),
        );
      }
      if (_textContent != null) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            _textContent!,
            style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          ),
        );
      }
    }

    // For PDF and other documents, show preview card with options
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Card(
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _getFileIcon(),
                  size: 120,
                  color: Theme.of(context).primaryColor,
                ),
                const SizedBox(height: 24),
                Text(
                  widget.fileName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _getFileTypeLabel(),
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: 200,
                  child: ElevatedButton.icon(
                    onPressed: _openInBrowser,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('Open in Browser'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 200,
                  child: OutlinedButton.icon(
                    onPressed: _isLoading ? null : _downloadDocument,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download),
                    label: Text(_isLoading ? 'Downloading...' : 'Download'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                if (kIsWeb && widget.fileType == 'pdf') ...[
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline, size: 16, color: Colors.blue[700]),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'PDF will open in a new browser tab',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue[700],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
