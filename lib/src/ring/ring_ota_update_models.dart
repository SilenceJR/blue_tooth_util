import 'ring_models.dart';
import 'ring_ota_transfer_models.dart';

/// 跨连接 OTA 更新阶段。
enum RingOtaUpdatePhase {
  idle,
  scanningOta,
  connectingOta,
  transferring,
  recovering,
  verifyingVersion,
  completed,
  failed,
  cancelled,
}

/// 跨连接 OTA 状态快照。
class RingOtaUpdateSnapshot {
  const RingOtaUpdateSnapshot({
    required this.phase,
    required this.round,
    required this.maxRounds,
    required this.acknowledgedBytes,
    required this.totalBytes,
    this.partitionIndex,
    this.transferPhase,
    this.message,
  });

  final RingOtaUpdatePhase phase;
  final int round;
  final int maxRounds;
  final int? partitionIndex;
  final RingOtaTransferPhase? transferPhase;
  final int acknowledgedBytes;
  final int totalBytes;
  final String? message;
}

/// 已由业务模式 `0x0402` 确认的 OTA 最终结果。
class RingOtaUpdateResult {
  const RingOtaUpdateResult({
    required this.targetFirmwareVersion,
    required this.confirmedOtaInfo,
    required this.roundCount,
  });

  final int targetFirmwareVersion;
  final RingOtaInfo confirmedOtaInfo;
  final int roundCount;
}
