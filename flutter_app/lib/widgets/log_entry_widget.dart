import 'package:flutter/material.dart';

import '../models/log_entry.dart';
import '../utils/log_formatter.dart';

/// Widget for rendering a single log entry with color-coded level and source.
class LogEntryWidget extends StatelessWidget {
  final LogEntry entry;

  const LogEntryWidget({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final levelColor = LogFormatter.levelColor(entry.level);
    final sourceColor = LogFormatter.sourceColor(entry.source);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Level indicator dot.
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: levelColor,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Timestamp.
          Text(
            LogFormatter.formatTimestamp(entry.timestamp),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),

          // Level badge.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: levelColor.withAlpha(30),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              entry.level.toUpperCase(),
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: levelColor,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 6),

          // Source badge.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: sourceColor.withAlpha(30),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              entry.source,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: sourceColor,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Message text.
          Expanded(
            child: Text(
              entry.message,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 11,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
