import 'package:flutter/material.dart';
import '../models/log_entry.dart';

/// Utility class for formatting and colorizing log entries in the UI.
class LogFormatter {
  LogFormatter._();

  /// Returns the color for a log level.
  static Color levelColor(String level) {
    switch (level.toLowerCase()) {
      case 'error':
        return const Color(0xFFE53935); // Red
      case 'warn':
        return const Color(0xFFFFA726); // Orange/Yellow
      case 'info':
        return const Color(0xFF43A047); // Green
      case 'debug':
        return const Color(0xFF1E88E5); // Blue
      case 'trace':
        return const Color(0xFF9E9E9E); // Grey
      default:
        return const Color(0xFF9E9E9E);
    }
  }

  /// Returns the icon for a log level.
  static IconData levelIcon(String level) {
    switch (level.toLowerCase()) {
      case 'error':
        return Icons.error;
      case 'warn':
        return Icons.warning;
      case 'info':
        return Icons.info;
      case 'debug':
        return Icons.bug_report;
      case 'trace':
        return Icons.track_changes;
      default:
        return Icons.circle;
    }
  }

  /// Returns the color for a log source component.
  static Color sourceColor(String source) {
    switch (source.toLowerCase()) {
      case 'xray':
        return const Color(0xFF7C4DFF); // Purple
      case 'arti':
        return const Color(0xFF00BCD4); // Cyan
      case 'hev':
        return const Color(0xFFFF7043); // Deep Orange
      case 'vpn':
        return const Color(0xFF66BB6A); // Green
      case 'ipc':
        return const Color(0xFF42A5F5); // Light Blue
      case 'main':
        return const Color(0xFF78909C); // Blue Grey
      default:
        return const Color(0xFF9E9E9E);
    }
  }

  /// Formats a timestamp for display (HH:MM:SS.mmm).
  static String formatTimestamp(String timestamp) {
    if (timestamp.length >= 23) {
      return timestamp.substring(11, 23);
    }
    return timestamp;
  }

  /// Formats byte count to human-readable form.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Filters log entries based on level filter and source filter.
  static List<LogEntry> filterEntries(
    List<LogEntry> entries, {
    String? levelFilter,
    String? sourceFilter,
    String? searchQuery,
  }) {
    return entries.where((entry) {
      if (levelFilter != null &&
          levelFilter.isNotEmpty &&
          levelFilter.toLowerCase() != 'all') {
        if (entry.level.toLowerCase() != levelFilter.toLowerCase()) {
          return false;
        }
      }

      if (sourceFilter != null &&
          sourceFilter.isNotEmpty &&
          sourceFilter.toLowerCase() != 'all') {
        if (entry.source.toLowerCase() != sourceFilter.toLowerCase()) {
          return false;
        }
      }

      if (searchQuery != null && searchQuery.isNotEmpty) {
        return entry.matchesSearch(searchQuery);
      }

      return true;
    }).toList();
  }

  /// Converts a log entry to a single-line export format.
  static String toExportLine(LogEntry entry) {
    final buf = StringBuffer();
    buf.write(entry.timestamp);
    buf.write(' [${entry.level.toUpperCase()}]');
    buf.write(' [${entry.source}]');
    buf.write(' ${entry.message}');
    if (entry.context != null && entry.context!.isNotEmpty) {
      buf.write(' ${entry.context}');
    }
    return buf.toString();
  }
}
