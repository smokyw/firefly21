import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../providers/vpn_provider.dart';

/// Settings tab — configuration management, TOR settings, and advanced options.
class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  int _versionTapCount = 0;

  // Exit node country options.
  static const _countries = {
    'DE': 'Germany',
    'US': 'United States',
    'NL': 'Netherlands',
    'CH': 'Switzerland',
    'SE': 'Sweden',
    'FI': 'Finland',
    'NO': 'Norway',
    'AT': 'Austria',
    'RO': 'Romania',
    'IS': 'Iceland',
  };

  static const _logLevels = ['trace', 'debug', 'info', 'warn', 'error'];

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Settings', style: theme.textTheme.titleLarge),
          const SizedBox(height: 24),

          // --- Configuration Section ---
          _SectionHeader(title: 'Configuration'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.link),
                  title: const Text('Import from URL'),
                  subtitle: Text(
                    settings.configUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showUrlDialog(context, ref, settings.configUrl),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.qr_code_scanner),
                  title: const Text('Import from QR Code'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showQRScanner(context, ref),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Manual Edit'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showManualEditor(context, ref, settings),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- TOR Settings Section ---
          _SectionHeader(title: 'TOR Settings'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.public),
                  title: const Text('Exit Node Country'),
                  trailing: DropdownButton<String>(
                    value: settings.exitCountry,
                    underline: const SizedBox.shrink(),
                    items: _countries.entries
                        .map((e) => DropdownMenuItem(
                              value: e.key,
                              child: Text('${_countryFlag(e.key)} ${e.key}'),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        ref.read(settingsProvider.notifier).updateExitCountry(value);
                      }
                    },
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                SwitchListTile(
                  secondary: const Icon(Icons.security),
                  title: const Text('Use Bridges'),
                  value: settings.useBridges,
                  onChanged: (_) =>
                      ref.read(settingsProvider.notifier).toggleBridges(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- Advanced Section ---
          _SectionHeader(title: 'Advanced'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.speed),
                  title: const Text('Skip Arti (direct mode)'),
                  subtitle: const Text('Bypass TOR, connect via xray only'),
                  value: settings.skipArti,
                  onChanged: (_) =>
                      ref.read(settingsProvider.notifier).toggleSkipArti(),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.dns),
                  title: const Text('DoH Server IP (bypass)'),
                  subtitle: Text(
                    settings.dohServerIp.isEmpty
                        ? 'Not set'
                        : settings.dohServerIp,
                    style: theme.textTheme.bodySmall,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showDohIpDialog(context, ref, settings.dohServerIp),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('Log Level'),
                  trailing: DropdownButton<String>(
                    value: settings.logLevel,
                    underline: const SizedBox.shrink(),
                    items: _logLevels
                        .map((l) => DropdownMenuItem(
                              value: l,
                              child: Text(l[0].toUpperCase() + l.substring(1)),
                            ))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        ref.read(settingsProvider.notifier).updateLogLevel(value);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- About Section ---
          _SectionHeader(title: 'About'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Version'),
              subtitle: const Text('1.0.0'),
              onTap: () {
                _versionTapCount++;
                if (_versionTapCount >= 7) {
                  _versionTapCount = 0;
                  ref.read(settingsProvider.notifier).toggleDevMode();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        settings.devMode
                            ? 'Developer mode disabled'
                            : 'Developer mode enabled',
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
          ),

          // --- Developer Section (hidden, activated by 7 taps on version) ---
          if (settings.devMode) ...[
            const SizedBox(height: 16),
            _SectionHeader(title: 'Developer'),
            Card(
              color: colorScheme.errorContainer.withAlpha(30),
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.developer_mode, color: colorScheme.error),
                    title: const Text('Raw Metrics'),
                    subtitle: const Text('View raw performance data'),
                    onTap: () {
                      // Show raw metrics dialog.
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: Icon(Icons.bug_report, color: colorScheme.error),
                    title: const Text('State Dump'),
                    subtitle: const Text('Dump current service states'),
                    onTap: () {
                      // Dump current state.
                    },
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    leading: Icon(Icons.science, color: colorScheme.error),
                    title: const Text('Test Scenarios'),
                    subtitle: const Text('Run diagnostic tests'),
                    onTap: () {
                      // Run test scenarios.
                    },
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// Shows a dialog to input config URL.
  Future<void> _showUrlDialog(
      BuildContext context, WidgetRef ref, String currentUrl) async {
    final controller = TextEditingController(text: currentUrl);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Config URL'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'https://...',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      ref.read(settingsProvider.notifier).updateConfigUrl(result);
    }
  }

  /// Shows QR code scanner for config import.
  Future<void> _showQRScanner(BuildContext context, WidgetRef ref) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _QRScannerPage(
          onDetect: (url) {
            ref.read(settingsProvider.notifier).updateConfigUrl(url);
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Config URL updated: $url')),
            );
          },
        ),
      ),
    );
  }

  /// Shows the DoH server IP dialog.
  Future<void> _showDohIpDialog(
      BuildContext context, WidgetRef ref, String currentIp) async {
    final controller = TextEditingController(text: currentIp);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('DoH Server IP'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '1.2.3.4',
            helperText: 'Direct IP to bypass DNS blocking of DoH server',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context, '');
            },
            child: const Text('Clear'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null) {
      ref.read(settingsProvider.notifier).updateDohServerIp(result);
    }
  }

  /// Shows manual config editor.
  Future<void> _showManualEditor(
      BuildContext context, WidgetRef ref, VpnSettings settings) async {
    // For now, shows a simple text editor for the config URL.
    // In the full implementation, this would open a JSON editor.
    _showUrlDialog(context, ref, settings.configUrl);
  }

  /// Returns a flag emoji for a country code.
  String _countryFlag(String code) {
    final base = 0x1F1E6;
    final chars = code.toUpperCase().codeUnits.map((c) => base + c - 65);
    return String.fromCharCodes(chars);
  }
}

/// Section header widget.
class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// QR code scanner page for config import.
class _QRScannerPage extends StatelessWidget {
  final void Function(String url) onDetect;
  const _QRScannerPage({required this.onDetect});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: MobileScanner(
        onDetect: (capture) {
          final barcode = capture.barcodes.firstOrNull;
          if (barcode?.rawValue != null) {
            onDetect(barcode!.rawValue!);
          }
        },
      ),
    );
  }
}
