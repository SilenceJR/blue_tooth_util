import 'dart:async';

import 'package:common/common.dart';

import '../common/ble_failure.dart';
import '../core/ble_scan_device.dart';
import '../core/ble_transport.dart';
import 'ring_ble_session.dart';
import 'ring_models.dart';
import 'ring_ota_package.dart';
import 'ring_ota_protocol.dart';
import 'ring_ota_session.dart';
import 'ring_ota_transfer_models.dart';
import 'ring_ota_update_models.dart';

/// 管理 OTA 模式重连、整包恢复和业务模式最终版本确认。
///
/// 每次恢复都创建新的 [RingOtaSession] 并从 START_OTA 开始；实现使用单层
/// 循环，不递归调用更新或传输。扫描命中名称/Service 后仍会用 Manufacturer
/// Data 中的 MAC 确认目标。
class RingOtaUpdateSession {
  factory RingOtaUpdateSession({
    required BleTransport transport,
    required RingDeviceIdentity identity,
    Duration scanTimeout = const Duration(seconds: 20),
    Duration versionConfirmationTimeout = const Duration(seconds: 60),
  }) => RingOtaUpdateSession._(
    transport,
    identity,
    scanTimeout,
    versionConfirmationTimeout,
  );

  RingOtaUpdateSession._(
    this._transport,
    this._identity,
    this.scanTimeout,
    this.versionConfirmationTimeout,
  );

  static const maxTransferRounds = 3;

  final BleTransport _transport;
  final RingDeviceIdentity _identity;
  final Duration scanTimeout;
  final Duration versionConfirmationTimeout;
  final _snapshots = StreamController<RingOtaUpdateSnapshot>.broadcast();

  RingOtaSession? _otaSession;
  StreamSubscription<RingOtaTransferSnapshot>? _transferSubscription;
  Completer<Result<BleScanDevice, BleFailure>>? _scanCompleter;
  Completer<Result<RingOtaInfo, BleFailure>>? _verificationCancellation;
  Completer<void>? _updateCompletion;
  String? _connectedDeviceId;
  bool _busy = false;
  bool _cancelRequested = false;
  bool _disposed = false;
  bool _disposeRequested = false;
  Future<void>? _disposing;
  bool _bootloaderCompleteThisRound = false;

  Stream<RingOtaUpdateSnapshot> get snapshotStream => _snapshots.stream;

  /// 执行最多三轮 START_OTA，并在业务模式以 `0x0402` 确认目标版本。
  Future<Result<RingOtaUpdateResult, BleFailure>> update(
    RingOtaPackage package, {
    int burstSize = RingOtaProtocol.defaultBurstSize,
  }) async {
    if (_disposed || _disposeRequested) return Result.err(_disposedFailure());
    if (_busy) {
      return const Result.err(
        BleFailure(
          code: BleFailureCode.busy,
          message: 'Ring OTA update is busy',
        ),
      );
    }
    _busy = true;
    _cancelRequested = false;
    final completion = Completer<void>();
    _updateCompletion = completion;
    BleFailure? lastFailure;
    try {
      for (var round = 1; round <= maxTransferRounds; round++) {
        try {
          _bootloaderCompleteThisRound = false;
          _checkActive();
          _emit(
            package,
            round,
            round == 1
                ? RingOtaUpdatePhase.scanningOta
                : RingOtaUpdatePhase.recovering,
            message: lastFailure?.message,
          );
          final otaDevice = _unwrap(
            await _scanFor(
              _identity.matchesOtaDevice,
              timeout: scanTimeout,
              options: const BleScanOptions(unfiltered: true),
            ),
          );
          _checkActive();
          _emit(package, round, RingOtaUpdatePhase.connectingOta);
          _unwrap(await _transport.connect(otaDevice.deviceId));
          _connectedDeviceId = otaDevice.deviceId;
          _checkActive();

          final session = RingOtaSession(
            device: otaDevice,
            transport: _transport,
          );
          _otaSession = session;
          _transferSubscription = session.snapshotStream.listen(
            (snapshot) => _forwardTransfer(package, round, snapshot),
          );
          final initialization = await session.initialize();
          _checkActive();
          if (initialization case Err(:final error)) {
            lastFailure = error;
          } else {
            final transfer = await session.transfer(
              package,
              burstSize: burstSize,
            );
            _checkActive();
            if (transfer case Err(
              :final error,
            ) when !_bootloaderCompleteThisRound) {
              lastFailure = error;
            } else {
              if (transfer case Err(:final error)) lastFailure = error;
              await _releaseOtaSession(disconnect: transfer.isErr);
              _checkActive();
              final verification = await _verifyVersion(package, round);
              _checkActive();
              switch (verification) {
                case _VersionConfirmed(:final info):
                  _checkActive();
                  _emit(
                    package,
                    round,
                    RingOtaUpdatePhase.completed,
                    acknowledgedBytes: package.totalSize,
                  );
                  return Result.ok(
                    RingOtaUpdateResult(
                      targetFirmwareVersion: package.firmwareVersion,
                      confirmedOtaInfo: info,
                      roundCount: round,
                    ),
                  );
                case _OtaModeFound():
                  lastFailure = const BleFailure(
                    code: BleFailureCode.connectionFailed,
                    message:
                        'Ring returned to OTA mode before version confirmation',
                  );
                case _VerificationFailed(:final failure):
                  _abort(failure, allowRecovery: false);
              }
            }
          }
        } on _RingOtaUpdateAbort catch (abort) {
          if (!abort.allowRecovery) rethrow;
          lastFailure = abort.failure;
        }

        await _releaseOtaSession();
        if (!_isRecoverable(lastFailure) || round == maxTransferRounds) {
          _abort(lastFailure);
        }
      }
      _abort(lastFailure ?? _recoveryExhaustedFailure());
    } on _RingOtaUpdateAbort catch (abort) {
      _emit(
        package,
        _currentRoundFromSnapshot,
        abort.failure.code == BleFailureCode.cancelled
            ? RingOtaUpdatePhase.cancelled
            : RingOtaUpdatePhase.failed,
        message: abort.failure.message,
      );
      return Result.err(abort.failure);
    } finally {
      await _releaseOtaSession();
      await _transport.stopScan();
      _scanCompleter = null;
      _connectedDeviceId = null;
      _busy = false;
      _cancelRequested = false;
      if (identical(_updateCompletion, completion)) _updateCompletion = null;
      if (!completion.isCompleted) completion.complete();
    }
  }

  /// 取消扫描、当前传输和后续恢复；不会把 Bootloader 完成当作成功。
  void cancel() {
    if (!_busy) return;
    _cancelRequested = true;
    _otaSession?.cancelTransfer();
    final pending = _scanCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.complete(Result.err(_cancelledFailure()));
    }
    final verification = _verificationCancellation;
    if (verification != null && !verification.isCompleted) {
      verification.complete(Result.err(_cancelledFailure()));
    }
  }

  Future<void> dispose() {
    if (_disposed) return Future.value();
    final inFlight = _disposing;
    if (inFlight != null) return inFlight;
    _disposeRequested = true;
    cancel();
    final disposing = _disposeOnce();
    _disposing = disposing;
    return disposing;
  }

  Future<void> _disposeOnce() async {
    final completion = _updateCompletion;
    if (completion != null) await completion.future;
    _disposed = true;
    await _releaseOtaSession();
    await _transport.stopScan();
    await _snapshots.close();
  }

  int _currentRoundFromSnapshot = 1;

  void _emit(
    RingOtaPackage package,
    int round,
    RingOtaUpdatePhase phase, {
    int acknowledgedBytes = 0,
    int? partitionIndex,
    RingOtaTransferPhase? transferPhase,
    String? message,
  }) {
    if (_snapshots.isClosed) return;
    _currentRoundFromSnapshot = round;
    _snapshots.add(
      RingOtaUpdateSnapshot(
        phase: phase,
        round: round,
        maxRounds: maxTransferRounds,
        partitionIndex: partitionIndex,
        transferPhase: transferPhase,
        acknowledgedBytes: acknowledgedBytes,
        totalBytes: package.totalSize,
        message: message,
      ),
    );
  }

  void _forwardTransfer(
    RingOtaPackage package,
    int round,
    RingOtaTransferSnapshot snapshot,
  ) {
    if (snapshot.phase == RingOtaTransferPhase.bootloaderComplete) {
      _bootloaderCompleteThisRound = true;
    }
    _emit(
      package,
      round,
      RingOtaUpdatePhase.transferring,
      acknowledgedBytes: snapshot.acknowledgedBytes,
      partitionIndex: snapshot.partitionIndex,
      transferPhase: snapshot.phase,
    );
  }

  Future<_VersionVerification> _verifyVersion(
    RingOtaPackage package,
    int round,
  ) async {
    _emit(
      package,
      round,
      RingOtaUpdatePhase.verifyingVersion,
      acknowledgedBytes: package.totalSize,
    );
    final candidate = await _scanFor(
      (device) =>
          _identity.matchesApplicationDevice(device) ||
          _identity.matchesOtaDevice(device),
      timeout: versionConfirmationTimeout,
      options: const BleScanOptions(unfiltered: true),
    );
    if (candidate case Err(:final error)) {
      return _VerificationFailed(error);
    }
    final device = candidate.valueOrNull!;
    _checkActive();
    if (_identity.matchesOtaDevice(device)) return const _OtaModeFound();

    final connected = await _transport.connect(device.deviceId);
    if (connected case Err(:final error)) return _VerificationFailed(error);
    _connectedDeviceId = device.deviceId;
    _checkActive();
    final session = RingBleSession(device: device, transport: _transport);
    try {
      final initialized = await session.initialize();
      _checkActive();
      if (initialized case Err(:final error)) {
        return _VerificationFailed(error);
      }
      final cancellation = Completer<Result<RingOtaInfo, BleFailure>>();
      _verificationCancellation = cancellation;
      final info = await Future.any([
        session.queryOtaInfo(),
        cancellation.future,
      ]);
      if (identical(_verificationCancellation, cancellation)) {
        _verificationCancellation = null;
      }
      _checkActive();
      if (info case Err(:final error)) return _VerificationFailed(error);
      final value = info.valueOrNull!;
      if (value.firmwareVersion != package.firmwareVersion) {
        return _VerificationFailed(
          BleFailure(
            code: BleFailureCode.protocolError,
            message:
                'Ring firmware version ${value.firmwareVersion} does not match target ${package.firmwareVersion}',
          ),
        );
      }
      _checkActive();
      return _VersionConfirmed(value);
    } finally {
      _verificationCancellation = null;
      await session.dispose();
      await _transport.disconnect(device.deviceId);
      _connectedDeviceId = null;
    }
  }

  Future<Result<BleScanDevice, BleFailure>> _scanFor(
    bool Function(BleScanDevice) matches, {
    required Duration timeout,
    required BleScanOptions options,
  }) async {
    _checkActive();
    final completer = Completer<Result<BleScanDevice, BleFailure>>();
    _scanCompleter = completer;
    late final StreamSubscription<BleScanDevice> subscription;
    subscription = _transport.scanStream.listen(
      (device) {
        if (!completer.isCompleted && matches(device)) {
          completer.complete(Result.ok(device));
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) {
          completer.complete(
            Result.err(
              BleFailure(
                code: BleFailureCode.scanFailed,
                message: 'Ring OTA scan stream failed',
                cause: error,
              ),
            ),
          );
        }
      },
    );
    try {
      final started = await _transport.startScan(options);
      if (started case Err(:final error)) return Result.err(error);
      return await completer.future.timeout(
        timeout,
        onTimeout: () => const Result.err(
          BleFailure(
            code: BleFailureCode.timeout,
            message: 'Timed out waiting for the target ring advertisement',
          ),
        ),
      );
    } finally {
      if (identical(_scanCompleter, completer)) _scanCompleter = null;
      await subscription.cancel();
      await _transport.stopScan();
    }
  }

  Future<void> _releaseOtaSession({bool disconnect = true}) async {
    final subscription = _transferSubscription;
    _transferSubscription = null;
    await subscription?.cancel();
    final session = _otaSession;
    _otaSession = null;
    await session?.dispose();
    final deviceId = _connectedDeviceId;
    _connectedDeviceId = null;
    if (disconnect && deviceId != null) await _transport.disconnect(deviceId);
  }

  bool _isRecoverable(BleFailure failure) {
    if (const {
      BleFailureCode.connectionFailed,
      BleFailureCode.timeout,
      BleFailureCode.writeFailed,
      BleFailureCode.serviceNotFound,
    }.contains(failure.code)) {
      return true;
    }
    final cause = failure.cause;
    if (cause is! RingOtaDeviceFailure) return false;
    return const {
      RingOtaDeviceError.spiFlash,
      RingOtaDeviceError.invalidState,
      RingOtaDeviceError.crc,
      RingOtaDeviceError.badData,
    }.contains(cause.error);
  }

  void _checkActive() {
    if (_disposed) _abort(_disposedFailure());
    if (_cancelRequested) _abort(_cancelledFailure());
  }

  T _unwrap<T>(Result<T, BleFailure> result) {
    return result.match(ok: (value) => value, err: _abort);
  }

  Never _abort(BleFailure failure, {bool allowRecovery = true}) =>
      throw _RingOtaUpdateAbort(failure, allowRecovery: allowRecovery);

  BleFailure _cancelledFailure() => const BleFailure(
    code: BleFailureCode.cancelled,
    message: 'Ring OTA update was cancelled',
  );

  BleFailure _disposedFailure() => const BleFailure(
    code: BleFailureCode.connectionFailed,
    message: 'Ring OTA update session is disposed',
  );

  BleFailure _recoveryExhaustedFailure() => const BleFailure(
    code: BleFailureCode.connectionFailed,
    message: 'Ring OTA recovery attempts were exhausted',
  );
}

sealed class _VersionVerification {
  const _VersionVerification();
}

class _VersionConfirmed extends _VersionVerification {
  const _VersionConfirmed(this.info);

  final RingOtaInfo info;
}

class _OtaModeFound extends _VersionVerification {
  const _OtaModeFound();
}

class _VerificationFailed extends _VersionVerification {
  const _VerificationFailed(this.failure);

  final BleFailure failure;
}

class _RingOtaUpdateAbort implements Exception {
  const _RingOtaUpdateAbort(this.failure, {this.allowRecovery = true});

  final BleFailure failure;
  final bool allowRecovery;
}
