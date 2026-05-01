import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/vpn_provider.dart';

/// Per-App Routing tab.
///
/// Users can choose between "Include only" and "Exclude" modes,
/// then select which apps should be routed through the VPN.
///
/// Uses VpnService.Builder.addAllowedApplication() / addDisallowedApplication()
/// on the Android side.
class AppsTab extends ConsumerStatefulWidget {
  const AppsTab({super.key});

  @override
  ConsumerState<AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends ConsumerState<AppsTab> {
  static const _channel = MethodChannel('com.example.vpntor/apps');

  List<AppInfo> _installedApps = [];
  List<AppInfo> _filteredApps = [];
  bool _loading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadInstalledApps();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInstalledApps() async {
    setState(() => _loading = true);
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getInstalledApps');
      if (result != null) {
        _installedApps = result
            .map((e) => AppInfo.fromMap(e as Map<dynamic, dynamic>))
            .toList()
          ..sort((a, b) => a.label.compareTo(b.label));
      }
    } on PlatformException {
      // Fallback: empty list if the platform channel is not available.
      _installedApps = [];
    } catch (e) {
      _installedApps = [];
    }
    _filteredApps = List.from(_installedApps);
    setState(() => _loading = false);
  }

  void _filterApps(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredApps = List.from(_installedApps);
      } else {
        final lower = query.toLowerCase();
        _filteredApps = _installedApps
            .where((app) =>
                app.label.toLowerCase().contains(lower) ||
                app.packageName.toLowerCase().contains(lower))
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final appRouting = ref.watch(appRoutingProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SafeArea(
      child: Column(
        children: [
          // Header.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Per-App Routing',
              style: theme.textTheme.titleLarge,
            ),
          ),

          // Mode selector: Include / Exclude.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: _ModeButton(
                    label: 'Include only',
                    isSelected: appRouting.mode == 'include',
                    onTap: () =>
                        ref.read(appRoutingProvider.notifier).setMode('include'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ModeButton(
                    label: 'Exclude',
                    isSelected: appRouting.mode == 'exclude',
                    onTap: () =>
                        ref.read(appRoutingProvider.notifier).setMode('exclude'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Search bar.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search apps...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: _filterApps,
            ),
          ),
          const SizedBox(height: 8),

          // Select all / Clear all.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  '${appRouting.selectedApps.length} selected',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    ref.read(appRoutingProvider.notifier).selectAll(
                          _installedApps.map((a) => a.packageName).toList(),
                        );
                  },
                  child: const Text('Select All'),
                ),
                TextButton(
                  onPressed: () {
                    ref.read(appRoutingProvider.notifier).clearAll();
                  },
                  child: const Text('Clear All'),
                ),
              ],
            ),
          ),

          // App list.
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _filteredApps.isEmpty
                    ? Center(
                        child: Text(
                          'No apps found',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: colorScheme.outline,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _filteredApps.length,
                        itemBuilder: (context, index) {
                          final app = _filteredApps[index];
                          final isSelected =
                              appRouting.selectedApps.contains(app.packageName);

                          return ListTile(
                            leading: app.icon != null
                                ? Image.memory(
                                    app.icon!,
                                    width: 40,
                                    height: 40,
                                  )
                                : CircleAvatar(
                                    backgroundColor:
                                        colorScheme.primaryContainer,
                                    child: Text(
                                      app.label.isNotEmpty
                                          ? app.label[0].toUpperCase()
                                          : '?',
                                      style: TextStyle(
                                        color: colorScheme.onPrimaryContainer,
                                      ),
                                    ),
                                  ),
                            title: Text(
                              app.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              app.packageName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            trailing: Checkbox(
                              value: isSelected,
                              onChanged: (_) {
                                ref
                                    .read(appRoutingProvider.notifier)
                                    .toggleApp(app.packageName);
                              },
                            ),
                            onTap: () {
                              ref
                                  .read(appRoutingProvider.notifier)
                                  .toggleApp(app.packageName);
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: isSelected ? colorScheme.primaryContainer : colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 18,
                color: isSelected ? colorScheme.primary : colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lightweight app info model.
class AppInfo {
  final String packageName;
  final String label;
  final Uint8List? icon;

  const AppInfo({
    required this.packageName,
    required this.label,
    this.icon,
  });

  factory AppInfo.fromMap(Map<dynamic, dynamic> map) {
    return AppInfo(
      packageName: map['packageName'] as String? ?? '',
      label: map['label'] as String? ?? '',
      icon: map['icon'] as Uint8List?,
    );
  }
}
