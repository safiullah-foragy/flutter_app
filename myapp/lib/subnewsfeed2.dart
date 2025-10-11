import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

Widget commentItem(Map<String, dynamic> comment, {required VoidCallback? onEdit, required VoidCallback? onDelete}) {
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 5.0),
    padding: const EdgeInsets.all(8.0),
    decoration: BoxDecoration(
      color: Colors.grey[100],
      borderRadius: BorderRadius.circular(8.0),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 15,
          backgroundColor: Colors.grey[300],
          backgroundImage: comment['user_data']?['profile_image'] != null
              ? CachedNetworkImageProvider(comment['user_data']['profile_image'])
              : null,
          child: comment['user_data']?['profile_image'] == null
              ? const Icon(Icons.person, size: 15, color: Colors.grey)
              : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(comment['user_data']?['name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              const SizedBox(height: 4),
              Text(comment['text'] ?? ''),
            ],
          ),
        ),
        if (onEdit != null) IconButton(icon: const Icon(Icons.edit, size: 16), onPressed: onEdit),
        if (onDelete != null) IconButton(icon: const Icon(Icons.delete, size: 16), onPressed: onDelete),
      ],
    ),
  );
}
