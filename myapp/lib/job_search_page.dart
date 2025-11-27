import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';

class JobSearchPage extends StatefulWidget {
  const JobSearchPage({super.key});

  @override
  State<JobSearchPage> createState() => _JobSearchPageState();
}

class _JobSearchPageState extends State<JobSearchPage> {
  // TODO: Replace with your deployed Render URL
  static const String apiBaseUrl = 'https://your-job-api.onrender.com';
  
  List<JobCircular> jobs = [];
  List<JobCircular> filteredJobs = [];
  bool isLoading = true;
  bool hasError = false;
  String errorMessage = '';
  String searchQuery = '';
  String? selectedSource;
  List<String> sources = [];
  
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchJobs();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchJobs() async {
    setState(() {
      isLoading = true;
      hasError = false;
    });

    try {
      final response = await http.get(
        Uri.parse('$apiBaseUrl/api/jobs?limit=100'),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['success'] == true) {
          final jobsList = (data['data'] as List)
              .map((job) => JobCircular.fromJson(job))
              .toList();
          
          setState(() {
            jobs = jobsList;
            filteredJobs = jobsList;
            sources = _extractSources(jobsList);
            isLoading = false;
          });
        } else {
          throw Exception('API returned success: false');
        }
      } else {
        throw Exception('Server returned ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        isLoading = false;
        hasError = true;
        errorMessage = 'Failed to load jobs: $e';
      });
    }
  }

  List<String> _extractSources(List<JobCircular> jobsList) {
    final sourceSet = jobsList.map((job) => job.source).toSet();
    return ['All', ...sourceSet.toList()..sort()];
  }

  void _filterJobs() {
    setState(() {
      filteredJobs = jobs.where((job) {
        final matchesSearch = searchQuery.isEmpty ||
            job.title.toLowerCase().contains(searchQuery.toLowerCase()) ||
            job.description.toLowerCase().contains(searchQuery.toLowerCase());
        
        final matchesSource = selectedSource == null ||
            selectedSource == 'All' ||
            job.source == selectedSource;
        
        return matchesSearch && matchesSource;
      }).toList();
    });
  }

  void _onSearchChanged(String query) {
    setState(() {
      searchQuery = query;
    });
    _filterJobs();
  }

  void _onSourceChanged(String? source) {
    setState(() {
      selectedSource = source;
    });
    _filterJobs();
  }

  Future<void> _launchUrl(String urlString) async {
    final url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open job link')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Job Search'),
        elevation: 2,
      ),
      body: Column(
        children: [
          // Search and Filter Section
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).cardColor,
            child: Column(
              children: [
                // Search Bar
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search jobs...',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _onSearchChanged('');
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: Theme.of(context).scaffoldBackgroundColor,
                  ),
                  onChanged: _onSearchChanged,
                ),
                const SizedBox(height: 12),
                
                // Source Filter Dropdown
                if (sources.isNotEmpty)
                  DropdownButtonFormField<String>(
                    value: selectedSource ?? 'All',
                    decoration: InputDecoration(
                      labelText: 'Filter by Source',
                      prefixIcon: const Icon(Icons.filter_list),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      filled: true,
                      fillColor: Theme.of(context).scaffoldBackgroundColor,
                    ),
                    items: sources.map((source) {
                      return DropdownMenuItem(
                        value: source,
                        child: Text(source),
                      );
                    }).toList(),
                    onChanged: _onSourceChanged,
                  ),
              ],
            ),
          ),

          // Job Count
          if (!isLoading && !hasError)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              width: double.infinity,
              child: Text(
                '${filteredJobs.length} job${filteredJobs.length == 1 ? '' : 's'} found',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ),

          // Job List
          Expanded(
            child: _buildContent(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _fetchJobs,
        child: const Icon(Icons.refresh),
        tooltip: 'Refresh Jobs',
      ),
    );
  }

  Widget _buildContent() {
    if (isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading job circulars...'),
          ],
        ),
      );
    }

    if (hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Failed to load jobs',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                errorMessage,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _fetchJobs,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (filteredJobs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              searchQuery.isEmpty
                  ? 'No jobs available'
                  : 'No jobs found matching your search',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchJobs,
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: filteredJobs.length,
        itemBuilder: (context, index) {
          return _buildJobCard(filteredJobs[index]);
        },
      ),
    );
  }

  Widget _buildJobCard(JobCircular job) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _launchUrl(job.link),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title
              Text(
                job.title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: Colors.blue[800],
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),

              // Source Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Text(
                  job.source,
                  style: TextStyle(
                    color: Colors.blue[700],
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Description
              if (job.description.isNotEmpty)
                Text(
                  job.description,
                  style: Theme.of(context).textTheme.bodyMedium,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 12),

              // Date and Deadline Row
              Row(
                children: [
                  if (job.postedDate != 'N/A') ...[
                    const Icon(Icons.calendar_today, size: 14, color: Colors.grey),
                    const SizedBox(width: 4),
                    Text(
                      'Posted: ${job.postedDate}',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                  if (job.postedDate != 'N/A' && job.deadline != 'N/A')
                    const SizedBox(width: 16),
                  if (job.deadline != 'N/A') ...[
                    const Icon(Icons.access_time, size: 14, color: Colors.red),
                    const SizedBox(width: 4),
                    Text(
                      'Deadline: ${job.deadline}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),

              // View Details Button
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: () => _launchUrl(job.link),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('View Details'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class JobCircular {
  final String title;
  final String source;
  final String sourceUrl;
  final String link;
  final String description;
  final String postedDate;
  final String deadline;
  final String scrapedAt;

  JobCircular({
    required this.title,
    required this.source,
    required this.sourceUrl,
    required this.link,
    required this.description,
    required this.postedDate,
    required this.deadline,
    required this.scrapedAt,
  });

  factory JobCircular.fromJson(Map<String, dynamic> json) {
    return JobCircular(
      title: json['title'] ?? '',
      source: json['source'] ?? '',
      sourceUrl: json['sourceUrl'] ?? '',
      link: json['link'] ?? '',
      description: json['description'] ?? '',
      postedDate: json['postedDate'] ?? 'N/A',
      deadline: json['deadline'] ?? 'N/A',
      scrapedAt: json['scrapedAt'] ?? '',
    );
  }
}
