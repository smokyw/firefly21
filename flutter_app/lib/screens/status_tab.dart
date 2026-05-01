import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/vpn_state.dart';
import '../providers/vpn_provider.dart';

/// Status tab — main VPN connection interface.
/// Shows connection status, metrics, and the connect/disconnect button.
class StatusTab extends ConsumerWidget {
  const StatusTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vpnState = ref.watch(vpnStateProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            const SizedBox(height: 32),

            // App title.
            Text(
              'VPN+TOR',
              style: theme.textTheme.headlineLarge?.copyWith(
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 48),

            // Status indicator — large pulsating circle.
            _StatusIndicator(vpnState: vpnState),
            const SizedBox(height: 24),

            // Connection info card.
            if (vpnState.status == VpnStatus.connected)
              _ConnectionInfoCard(vpnState: vpnState),

            // Progress bar during connection.
            if (vpnState.status == VpnStatus.connecting)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: vpnState.connectProgress,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(vpnState.connectProgress * 100).toInt()}%',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),

            // Error message.
            if (vpnState.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Card(
                  color: colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.error, color: colorScheme.error),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            vpnState.errorMessage!,
                            style: TextStyle(color: colorScheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            const Spacer(),

            // Connect / Disconnect button.
            _ConnectButton(vpnState: vpnState),
            const SizedBox(height: 16),

            // Quick actions.
            if (vpnState.status == VpnStatus.connected)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () =>
                        ref.read(vpnStateProvider.notifier).reconnect(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reconnect'),
                  ),
                  const SizedBox(width: 16),
                  TextButton.icon(
                    onPressed: () {
                      // Navigate to settings to change exit node.
                    },
                    icon: const Icon(Icons.public),
                    label: const Text('Change Exit'),
                  ),
                ],
              ),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

/// Large status indicator with animated color/icon.
class _StatusIndicator extends StatelessWidget {
  final VpnState vpnState;
  const _StatusIndicator({required this.vpnState});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    Color indicatorColor;
    IconData indicatorIcon;
    switch (vpnState.status) {
      case VpnStatus.connected:
        indicatorColor = const Color(0xFF43A047);
        indicatorIcon = Icons.shield;
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        indicatorColor = colorScheme.tertiary;
        indicatorIcon = Icons.sync;
      case VpnStatus.error:
        indicatorColor = colorScheme.error;
        indicatorIcon = Icons.error;
      case VpnStatus.disconnected:
        indicatorColor = colorScheme.outline;
        indicatorIcon = Icons.shield_outlined;
    }

    return Column(
      children: [
        // Animated circle indicator.
        AnimatedContainer(
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: indicatorColor.withAlpha(30),
            border: Border.all(color: indicatorColor, width: 3),
          ),
          child: Icon(
            indicatorIcon,
            size: 56,
            color: indicatorColor,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          vpnState.statusText,
          style: theme.textTheme.titleLarge?.copyWith(
            color: indicatorColor,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

/// Card showing connection details: exit node, protocol, latency, traffic.
class _ConnectionInfoCard extends StatelessWidget {
  final VpnState vpnState;
  const _ConnectionInfoCard({required this.vpnState});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            _InfoRow(
              icon: Icons.public,
              label: 'Exit',
              value:
                  '${vpnState.exitCountry ?? "Unknown"} ${vpnState.skipArti ? "(Direct)" : "(Tor)"}',
            ),
            const Divider(height: 16),
            _InfoRow(
              icon: Icons.lock,
              label: 'Protocol',
              value: vpnState.protocol ?? 'Unknown',
            ),
            const Divider(height: 16),
            _InfoRow(
              icon: Icons.speed,
              label: 'Latency',
              value: vpnState.latencyMs != null
                  ? '${vpnState.latencyMs} ms'
                  : '-- ms',
            ),
            const Divider(height: 16),
            Row(
              children: [
                Expanded(
                  child: _InfoRow(
                    icon: Icons.arrow_upward,
                    label: 'Upload',
                    value: vpnState.uploadText,
                  ),
                ),
                Expanded(
                  child: _InfoRow(
                    icon: Icons.arrow_downward,
                    label: 'Download',
                    value: vpnState.downloadText,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Connect / Disconnect button with animated state transitions.
class _ConnectButton extends ConsumerWidget {
  final VpnState vpnState;
  const _ConnectButton({required this.vpnState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final isConnected = vpnState.status == VpnStatus.connected;
    final isTransitioning = vpnState.status == VpnStatus.connecting ||
        vpnState.status == VpnStatus.disconnecting;

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        child: ElevatedButton(
          onPressed: isTransitioning
              ? null
              : () {
                  if (isConnected) {
                    ref.read(vpnStateProvider.notifier).disconnect();
                  } else {
                    ref.read(vpnStateProvider.notifier).connect();
                  }
                },
          style: ElevatedButton.styleFrom(
            backgroundColor:
                isConnected ? colorScheme.error : colorScheme.primary,
            foregroundColor:
                isConnected ? colorScheme.onError : colorScheme.onPrimary,
          ),
          child: isTransitioning
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(isConnected ? 'DISCONNECT' : 'CONNECT'),
        ),
      ),
    );
  }
}
