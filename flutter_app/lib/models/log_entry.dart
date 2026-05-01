/// Unified log entry model matching the Go core's JSON format.
///
/// Format: {timestamp, level, source, message, context?}
class LogEntry {
  final String timestamp;
  final String level;
  final String source;
  final String message;
  final Map<String, dynamic>? context;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.context,
  });

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      timestamp: json['timestamp'] as String? ?? '',
      level: json['level'] as String? ?? 'info',
      source: json['source'] as String? ?? 'unknown',
      message: json['message'] as String? ?? '',
      context: json['context'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp,
      'level': level,
      'source': source,
      'message': message,
      if (context != null) 'context': context,
    };
  }

  /// Returns a formatted string for display (without JSON structure).
  String toDisplayString() {
    final time = timestamp.length >= 19
        ? timestamp.substring(11, 23) // HH:MM:SS.mmm
        : timestamp;
    return '$time [$level] [$source] $message';
  }

  /// Returns true if this entry matches the given search query.
  bool matchesSearch(String query) {
    if (query.isEmpty) return true;
    final lower = query.toLowerCase();
    return message.toLowerCase().contains(lower) ||
        source.toLowerCase().contains(lower) ||
        level.toLowerCase().contains(lower);
  }
}
