/// VPN connection state model.
enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

/// Holds the full VPN connection state for the UI.
class VpnState {
  final VpnStatus status;
  final String? exitCountry;
  final String? protocol;
  final int? latencyMs;
  final int uploadBytes;
  final int downloadBytes;
  final double connectProgress;
  final String? errorMessage;
  final bool skipArti;

  const VpnState({
    this.status = VpnStatus.disconnected,
    this.exitCountry,
    this.protocol,
    this.latencyMs,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.connectProgress = 0.0,
    this.errorMessage,
    this.skipArti = false,
  });

  VpnState copyWith({
    VpnStatus? status,
    String? exitCountry,
    String? protocol,
    int? latencyMs,
    int? uploadBytes,
    int? downloadBytes,
    double? connectProgress,
    String? errorMessage,
    bool? skipArti,
  }) {
    return VpnState(
      status: status ?? this.status,
      exitCountry: exitCountry ?? this.exitCountry,
      protocol: protocol ?? this.protocol,
      latencyMs: latencyMs ?? this.latencyMs,
      uploadBytes: uploadBytes ?? this.uploadBytes,
      downloadBytes: downloadBytes ?? this.downloadBytes,
      connectProgress: connectProgress ?? this.connectProgress,
      errorMessage: errorMessage ?? this.errorMessage,
      skipArti: skipArti ?? this.skipArti,
    );
  }

  /// Human-readable status text for the UI.
  String get statusText {
    switch (status) {
      case VpnStatus.disconnected:
        return 'Disconnected';
      case VpnStatus.connecting:
        return 'Connecting...';
      case VpnStatus.connected:
        return 'Connected';
      case VpnStatus.disconnecting:
        return 'Disconnecting...';
      case VpnStatus.error:
        return 'Error';
    }
  }

  /// Formatted upload traffic string.
  String get uploadText => _formatBytes(uploadBytes);

  /// Formatted download traffic string.
  String get downloadText => _formatBytes(downloadBytes);

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
