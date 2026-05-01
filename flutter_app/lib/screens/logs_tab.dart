import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../models/log_entry.dart';
import '../providers/vpn_provider.dart';
import '../utils/log_formatter.dart';
import '../widgets/log_entry_widget.dart';

/// Logs tab — full-featured real-time log viewer.
///
/// Features:
/// - Real-time log streaming from all components
/// - Level filtering (All/Error/Warn/Info/Debug/Trace)
/// - Source filtering (hev/arti/xray/vpn/ipc)
/// - Full-text search
/// - Virtual list (max 1000 visible, scroll-to-load)
/// - Export to file
/// - Copy to clipboard
/// - Auto-scroll toggle
class LogsTab extends ConsumerStatefulWidget {
  const LogsTab({super.key});

  @override
  ConsumerState<LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends ConsumerState<LogsTab> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _levelFilter = 'all';
  String _sourceFilter = 'all';
  bool _autoScroll = true;

  static const _levelFilters = ['all', 'error', 'warn', 'info', 'debug', 'trace'];
  static const _sourceFilters = ['all', 'hev', 'arti', 'xray', 'vpn', 'ipc'];

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allEntries = ref.watch(logEntriesProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Apply filters.
    final filteredEntries = LogFormatter.filterEntries(
      allEntries,
      levelFilter: _levelFilter,
      sourceFilter: _sourceFilter,
      searchQuery: _searchController.text,
    );

    // Limit visible entries for performance (virtual list behavior).
    final visibleEntries = filteredEntries.length > 1000
        ? filteredEntries.sublist(filteredEntries.length - 1000)
        : filteredEntries;

    // Auto-scroll to bottom when new entries arrive.
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }

    return SafeArea(
      child: Column(
        children: [
          // Search bar.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search logs...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      )
                    : null,
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),

          // Level filter chips.
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: _levelFilters.map((level) {
                final isSelected = _levelFilter == level;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(
                      level == 'all' ? 'All' : level[0].toUpperCase() + level.substring(1),
                      style: TextStyle(
                        fontSize: 12,
                        color: isSelected && level != 'all'
                            ? Colors.white
                            : null,
                      ),
                    ),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() {
                        _levelFilter = selected ? level : 'all';
                      });
                    },
                    backgroundColor: level != 'all'
                        ? LogFormatter.levelColor(level).withAlpha(30)
                        : null,
                    selectedColor: level != 'all'
                        ? LogFormatter.levelColor(level)
                        : colorScheme.primaryContainer,
                    showCheckmark: false,
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),

          // Source filter chips.
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: _sourceFilters.map((source) {
                final isSelected = _sourceFilter == source;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(
                      source == 'all' ? 'All' : source,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() {
                        _sourceFilter = selected ? source : 'all';
                      });
                    },
                    selectedColor: source != 'all'
                        ? LogFormatter.sourceColor(source).withAlpha(60)
                        : colorScheme.primaryContainer,
                    showCheckmark: false,
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),

          // Log entries list.
          Expanded(
            child: visibleEntries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.article_outlined,
                          size: 64,
                          color: colorScheme.outline,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No log entries',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: visibleEntries.length,
                    itemBuilder: (context, index) {
                      return LogEntryWidget(entry: visibleEntries[index]);
                    },
                  ),
          ),

          // Bottom toolbar.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              border: Border(
                top: BorderSide(color: colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                // Auto-scroll toggle.
                IconButton(
                  icon: Icon(
                    _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
                    size: 20,
                  ),
                  tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
                  onPressed: () {
                    setState(() => _autoScroll = !_autoScroll);
                  },
                ),
                // Entry count.
                Text(
                  '${visibleEntries.length}/${allEntries.length}',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                // Clear logs.
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Clear logs',
                  onPressed: () {
                    ref.read(logEntriesProvider.notifier).clear();
                  },
                ),
                // Copy to clipboard.
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: 'Copy to clipboard',
                  onPressed: () {
                    final text =
                        ref.read(logEntriesProvider.notifier).exportAll();
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Logs copied to clipboard'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
                // Export to file.
                IconButton(
                  icon: const Icon(Icons.save_alt, size: 20),
                  tooltip: 'Export logs',
                  onPressed: () => _exportLogs(context, ref),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportLogs(BuildContext context, WidgetRef ref) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .substring(0, 15);
      final file = File('${dir.path}/logs/vpn_export_$timestamp.log');

      await file.parent.create(recursive: true);

      final text = ref.read(logEntriesProvider.notifier).exportAll();
      await file.writeAsString(text);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Logs exported to ${file.path}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }
}
