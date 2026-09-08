/// 单轮 OTA Bootloader 传输阶段。
enum RingOtaTransferPhase {
  idle,
  starting,
  declaringPartition,
  transferringPartition,
  awaitingPartitionComplete,
  bootloaderComplete,
  rebooting,
  cancelled,
  failed,
}

/// 单轮传输状态快照。
///
/// 确认字节只在 BLOCK_BURST 或分区终态应答后增加，不按每包写入刷新。
class RingOtaTransferSnapshot {
  const RingOtaTransferSnapshot({
    required this.phase,
    required this.partitionCount,
    required this.acknowledgedBytes,
    required this.totalBytes,
    this.partitionIndex,
  });

  final RingOtaTransferPhase phase;
  final int? partitionIndex;
  final int partitionCount;
  final int acknowledgedBytes;
  final int totalBytes;
}

/// Bootloader 单轮传输与延迟重启命令的结果。
///
/// 此结果不代表固件升级成功；仍必须在业务模式用 `0x0402` 确认版本。
class RingOtaTransferResult {
  const RingOtaTransferResult({
    required this.targetFirmwareVersion,
    required this.partitionCount,
    required this.acknowledgedBytes,
    required this.rebootAcknowledged,
  });

  final int targetFirmwareVersion;
  final int partitionCount;
  final int acknowledgedBytes;
  final bool rebootAcknowledged;

  /// 固定为 true，提醒调用方完成业务模式版本确认。
  bool get requiresVersionConfirmation => true;
}
