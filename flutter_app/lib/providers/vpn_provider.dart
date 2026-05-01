import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/log_entry.dart';
import '../models/vpn_state.dart';
import '../services/ipc_client.dart';

/// Platform channel for communicating with the Android VpnService.
const _channel = MethodChannel('com.example.vpntor/vpn');

/// Event channel for streaming log entries from the native core.
const _logChannel = EventChannel('com.example.vpntor/logs');

/// Provider for the VPN connection state.
final vpnStateProvider =
    StateNotifierProvider<VpnStateNotifier, VpnState>((ref) {
  return VpnStateNotifier(ref);
});

/// Provider for the log entries list.
final logEntriesProvider =
    StateNotifierProvider<LogEntriesNotifier, List<LogEntry>>((ref) {
  return LogEntriesNotifier();
});

/// Provider for per-app routing selections.
final appRoutingProvider =
    StateNotifierProvider<AppRoutingNotifier, AppRoutingState>((ref) {
  return AppRoutingNotifier();
});

/// Provider for VPN settings.
final settingsProvider =
    StateNotifierProvider<SettingsNotifier, VpnSettings>((ref) {
  return SettingsNotifier();
});

// ---------------------------------------------------------------------------
// VPN State Management
// ---------------------------------------------------------------------------

class VpnStateNotifier extends StateNotifier<VpnState> {
  final Ref _ref;
  final IpcClient _ipc = IpcClient();
  Timer? _statsTimer;

  VpnStateNotifier(this._ref) : super(const VpnState());

  /// Initiates a VPN connection.
  Future<void> connect() async {
    if (state.status == VpnStatus.connecting ||
        state.status == VpnStatus.connected) {
      return;
    }

    state = state.copyWith(
      status: VpnStatus.connecting,
      connectProgress: 0.0,
      errorMessage: null,
    );

    try {
      final settings = _ref.read(settingsProvider);
      final appRouting = _ref.read(appRoutingProvider);

      // Request VPN permission from Android.
      state = state.copyWith(connectProgress: 0.1);
      final prepared = await _channel.invokeMethod<bool>('prepareVpn') ?? false;
      if (!prepared) {
        state = state.copyWith(
          status: VpnStatus.error,
          errorMessage: 'VPN permission denied',
        );
        return;
      }

      state = state.copyWith(connectProgress: 0.2);

      // Connect to the Go core service via IPC.
      final socketPath =
          await _channel.invokeMethod<String>('getSocketPath') ?? '';
      if (socketPath.isNotEmpty) {
        await _ipc.connect(socketPath);
      }

      state = state.copyWith(connectProgress: 0.4);

      // Send connect command to the Go core.
      final params = <String, dynamic>{
        'config_url': settings.configUrl,
        'app_mode': appRouting.mode,
      };

      if (appRouting.mode == 'include') {
        params['allowed_apps'] = appRouting.selectedApps;
      } else if (appRouting.mode == 'exclude') {
        params['disallowed_apps'] = appRouting.selectedApps;
      }

      state = state.copyWith(connectProgress: 0.6);

      // Start the VPN service on the Android side.
      await _channel.invokeMethod('startVpn', params);

      state = state.copyWith(connectProgress: 0.8);

      // If IPC is connected, issue the connect command.
      if (_ipc.isConnected) {
        final result = await _ipc.call('connect', params);
        final resultMap = result as Map<String, dynamic>? ?? {};

        state = state.copyWith(
          status: VpnStatus.connected,
          connectProgress: 1.0,
          skipArti: resultMap['skip_arti'] as bool? ?? false,
          protocol: _extractProtocol(settings.configUrl),
        );
      } else {
        state = state.copyWith(
          status: VpnStatus.connected,
          connectProgress: 1.0,
        );
      }

      // Start periodic stats updates.
      _startStatsPolling();
    } on PlatformException catch (e) {
      state = state.copyWith(
        status: VpnStatus.error,
        errorMessage: 'Platform error: ${e.message}',
      );
    } catch (e) {
      state = state.copyWith(
        status: VpnStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  /// Disconnects the VPN.
  Future<void> disconnect() async {
    if (state.status == VpnStatus.disconnected ||
        state.status == VpnStatus.disconnecting) {
      return;
    }

    state = state.copyWith(status: VpnStatus.disconnecting);
    _stopStatsPolling();

    try {
      if (_ipc.isConnected) {
        await _ipc.call('disconnect');
        await _ipc.disconnect();
      }
      await _channel.invokeMethod('stopVpn');
      state = const VpnState(status: VpnStatus.disconnected);
    } catch (e) {
      state = state.copyWith(
        status: VpnStatus.error,
        errorMessage: 'Disconnect failed: $e',
      );
    }
  }

  /// Reconnects the VPN (disconnect then connect).
  Future<void> reconnect() async {
    await disconnect();
    // Brief delay to ensure cleanup completes.
    await Future.delayed(const Duration(milliseconds: 500));
    await connect();
  }

  void _startStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!_ipc.isConnected || state.status != VpnStatus.connected) {
        return;
      }
      try {
        final result = await _ipc.call('status');
        if (result is Map<String, dynamic>) {
          state = state.copyWith(
            latencyMs: (result['latency_ms'] as num?)?.toInt(),
            uploadBytes: (result['upload_bytes'] as num?)?.toInt(),
            downloadBytes: (result['download_bytes'] as num?)?.toInt(),
          );
        }
      } catch (_) {
        // Silently ignore stats polling failures.
      }
    });
  }

  void _stopStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  String _extractProtocol(String configUrl) {
    // Default protocol display until we get it from the config.
    return 'VLESS+TCP';
  }

  @override
  void dispose() {
    _stopStatsPolling();
    _ipc.disconnect();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Log Entries
// ---------------------------------------------------------------------------

class LogEntriesNotifier extends StateNotifier<List<LogEntry>> {
  StreamSubscription? _subscription;
  static const int maxEntries = 10000;

  LogEntriesNotifier() : super([]) {
    _startListening();
  }

  void _startListening() {
    _subscription = _logChannel.receiveBroadcastStream().listen((event) {
      if (event is String) {
        try {
          final json = jsonDecode(event) as Map<String, dynamic>;
          addEntry(LogEntry.fromJson(json));
        } catch (_) {}
      }
    });
  }

  void addEntry(LogEntry entry) {
    if (state.length >= maxEntries) {
      // Drop oldest entries when buffer is full (backpressure control).
      state = [...state.sublist(state.length - maxEntries + 1), entry];
    } else {
      state = [...state, entry];
    }
  }

  void clear() {
    state = [];
  }

  /// Returns entries filtered by level and source.
  List<LogEntry> filtered({String? level, String? source, String? search}) {
    return state.where((entry) {
      if (level != null && level != 'all' && entry.level != level) {
        return false;
      }
      if (source != null && source != 'all' && entry.source != source) {
        return false;
      }
      if (search != null && search.isNotEmpty && !entry.matchesSearch(search)) {
        return false;
      }
      return true;
    }).toList();
  }

  /// Exports all entries as a formatted string.
  String exportAll() {
    final buffer = StringBuffer();
    for (final entry in state) {
      buffer.writeln(entry.toDisplayString());
    }
    return buffer.toString();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Per-App Routing
// ---------------------------------------------------------------------------

class AppRoutingState {
  final String mode; // 'include', 'exclude', or 'all'
  final List<String> selectedApps; // Package names

  const AppRoutingState({
    this.mode = 'all',
    this.selectedApps = const [],
  });

  AppRoutingState copyWith({
    String? mode,
    List<String>? selectedApps,
  }) {
    return AppRoutingState(
      mode: mode ?? this.mode,
      selectedApps: selectedApps ?? this.selectedApps,
    );
  }
}

class AppRoutingNotifier extends StateNotifier<AppRoutingState> {
  AppRoutingNotifier() : super(const AppRoutingState());

  void setMode(String mode) {
    state = state.copyWith(mode: mode);
  }

  void toggleApp(String packageName) {
    final apps = List<String>.from(state.selectedApps);
    if (apps.contains(packageName)) {
      apps.remove(packageName);
    } else {
      apps.add(packageName);
    }
    state = state.copyWith(selectedApps: apps);
  }

  void selectAll(List<String> packageNames) {
    state = state.copyWith(selectedApps: packageNames);
  }

  void clearAll() {
    state = state.copyWith(selectedApps: []);
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class VpnSettings {
  final String configUrl;
  final String exitCountry;
  final bool useBridges;
  final bool skipArti;
  final String dohServerIp;
  final String logLevel;
  final bool devMode;

  const VpnSettings({
    this.configUrl = 'https://incss.ru/vless.conf',
    this.exitCountry = 'DE',
    this.useBridges = false,
    this.skipArti = false,
    this.dohServerIp = '',
    this.logLevel = 'debug',
    this.devMode = false,
  });

  VpnSettings copyWith({
    String? configUrl,
    String? exitCountry,
    bool? useBridges,
    bool? skipArti,
    String? dohServerIp,
    String? logLevel,
    bool? devMode,
  }) {
    return VpnSettings(
      configUrl: configUrl ?? this.configUrl,
      exitCountry: exitCountry ?? this.exitCountry,
      useBridges: useBridges ?? this.useBridges,
      skipArti: skipArti ?? this.skipArti,
      dohServerIp: dohServerIp ?? this.dohServerIp,
      logLevel: logLevel ?? this.logLevel,
      devMode: devMode ?? this.devMode,
    );
  }
}

class SettingsNotifier extends StateNotifier<VpnSettings> {
  SettingsNotifier() : super(const VpnSettings());

  void updateConfigUrl(String url) =>
      state = state.copyWith(configUrl: url);
  void updateExitCountry(String country) =>
      state = state.copyWith(exitCountry: country);
  void toggleBridges() =>
      state = state.copyWith(useBridges: !state.useBridges);
  void toggleSkipArti() =>
      state = state.copyWith(skipArti: !state.skipArti);
  void updateDohServerIp(String ip) =>
      state = state.copyWith(dohServerIp: ip);
  void updateLogLevel(String level) =>
      state = state.copyWith(logLevel: level);
  void toggleDevMode() =>
      state = state.copyWith(devMode: !state.devMode);
}
