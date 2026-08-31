import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:common/common.dart';

import '../common/ble_failure.dart';
import '../core/ble_scan_device.dart';
import '../core/ble_session.dart';
import '../core/ble_transport.dart';
import 'ring_ota_package.dart';
import 'ring_ota_protocol.dart';
import 'ring_ota_transfer_models.dart';

/// 已连接的戒指 OTA Bootloader 会话。
class RingOtaSession implements BleSession {
  factory RingOtaSession({
    required BleScanDevice device,
    required BleTransport transport,
  }) => RingOtaSession._(device, transport);

  RingOtaSession._(this._device, this._transport);

  final BleScanDevice _device;
  final BleTransport _transport;
  final List<StreamSubscription> _subscriptions = [];
  final Queue<Result<RingOtaResponse, BleFailure>> _responseQueue = Queue();
  final _snapshots = StreamController<RingOtaTransferSnapshot>.broadcast();

  _PendingOtaResponse? _pendingResponse;
  Future<Result<void, BleFailure>>? _initializing;
  BleFailure? _streamFailure;
  bool _initialized = false;
  bool _disposed = false;
  bool _transferBusy = false;
  bool _cancelRequested = false;
  bool _requiresReconnect = false;
  bool _allowBufferedTerminal = false;
  int? _actualMtu;

  @override
  String get deviceId => _device.deviceId;

  @override
  Stream<bool> get connectionStream => _transport.connectionStream(deviceId);

  /// 协商后的实际 MTU；初始化成功前为空。
  int? get actualMtu => _actualMtu;

  /// 单个 Data 特征无响应写包长；初始化成功前为空。
  int? get packetSize => _actualMtu == null ? null : _actualMtu! - 3;

  /// 协议阶段和设备确认字节流，不逐包刷新。
  Stream<RingOtaTransferSnapshot> get snapshotStream => _snapshots.stream;

  @override
  Future<Result<void, BleFailure>> initialize() {
    if (_disposed) return Future.value(Result.err(_disposedFailure()));
    if (_initialized) return Future.value(const Result.ok(null));
    final inFlight = _initializing;
    if (inFlight != null) return inFlight;
    late final Future<Result<void, BleFailure>> initialization;
    initialization = _initializeOnce().whenComplete(() {
      if (identical(_initializing, initialization)) _initializing = null;
    });
    _initializing = initialization;
    return initialization;
  }

  Future<Result<void, BleFailure>> _initializeOnce() async {
    _subscriptions.add(
      connectionStream.listen((connected) {
        if (!connected) {
          _failResponseWait(
            const BleFailure(
              code: BleFailureCode.connectionFailed,
              message: 'OTA device disconnected',
            ),
          );
        }
      }, onError: _handleStreamError),
    );
    _subscriptions.add(
      _transport
          .valueStream(deviceId, RingOtaProtocol.responseCharacteristicUuid)
          .listen(_handleResponseValue, onError: _handleStreamError),
    );
    try {
      final mtuResult = await _transport.requestMtu(
        deviceId,
        RingOtaProtocol.requestedMtu,
      );
      final negotiatedMtu = _unwrap(mtuResult);
      _checkInitializationActive();
      final actual = math.min(negotiatedMtu, RingOtaProtocol.maximumMtu);
      if (actual < 23) {
        _abort(
          const BleFailure(
            code: BleFailureCode.unsupported,
            message: 'OTA negotiated MTU must be at least 23',
          ),
        );
      }
      final services = _unwrap(await _transport.discoverServices(deviceId));
      _checkInitializationActive();
      if (!_containsRequiredGatt(services)) {
        _abort(
          const BleFailure(
            code: BleFailureCode.serviceNotFound,
            message:
                'OTA service or required characteristic capability is missing',
          ),
        );
      }
      _unwrap(
        await _transport.subscribeNotifications(
          deviceId,
          RingOtaProtocol.serviceUuid,
          RingOtaProtocol.responseCharacteristicUuid,
        ),
      );
      _checkInitializationActive();
      _actualMtu = actual;
      _initialized = true;
      return const Result.ok(null);
    } on _RingOtaAbort catch (abort) {
      await _cancelSubscriptions();
      return Result.err(abort.failure);
    }
  }

  /// 执行一次无重试的 Bootloader 正常传输与延迟重启流程。
  Future<Result<RingOtaTransferResult, BleFailure>> transfer(
    RingOtaPackage package, {
    int burstSize = RingOtaProtocol.defaultBurstSize,
  }) async {
    if (_disposed) return Result.err(_disposedFailure());
    if (!_initialized) {
      return const Result.err(
        BleFailure(
          code: BleFailureCode.protocolError,
          message: 'OTA session is not initialized',
        ),
      );
    }
    if (_requiresReconnect || _streamFailure != null) {
      return Result.err(_reconnectFailure());
    }
    if (_transferBusy) {
      return const Result.err(
        BleFailure(code: BleFailureCode.busy, message: 'OTA transfer is busy'),
      );
    }
    if (burstSize < 1 || burstSize > 0xFE) {
      return const Result.err(
        BleFailure(
          code: BleFailureCode.protocolError,
          message: 'OTA burst size must be between 1 and 254',
        ),
      );
    }

    _transferBusy = true;
    _cancelRequested = false;
    var acknowledgedBytes = 0;
    try {
      _emit(package, RingOtaTransferPhase.starting, acknowledgedBytes);
      await _sendControl(
        RingOtaProtocol.startCommand(package.partitions.length, burstSize),
        RingOtaProtocol.responseStart,
      );

      for (final partition in package.partitions) {
        _checkActive();
        _emit(
          package,
          RingOtaTransferPhase.declaringPartition,
          acknowledgedBytes,
          partition.index,
        );
        await _sendControl(
          RingOtaProtocol.partitionInfoCommand(partition),
          RingOtaProtocol.responsePartitionInfo,
        );
        final data = partition.data;
        var offset = 0;
        var terminalReceived = false;
        while (offset < data.length) {
          _checkActive();
          if (_responseQueue.isNotEmpty) {
            _requiresReconnect = true;
            _abort(
              const BleFailure(
                code: BleFailureCode.protocolError,
                message: 'Unexpected buffered OTA response before data burst',
              ),
            );
          }
          final burstStart = offset;
          final packets = <Uint8List>[];
          for (
            var packet = 0;
            packet < burstSize && offset < data.length;
            packet++
          ) {
            final end = math.min(offset + packetSize!, data.length);
            packets.add(Uint8List.fromList(data.sublist(offset, end)));
            offset = end;
          }
          final isFullBurst =
              packets.length == burstSize &&
              packets.every((packet) => packet.length == packetSize);
          final endsPartition = offset == data.length;
          _allowBufferedTerminal = isFullBurst && endsPartition;
          final isLastPartition =
              partition.index == package.partitions.length - 1;
          final terminalCode = isLastPartition
              ? RingOtaProtocol.responseOtaComplete
              : RingOtaProtocol.responsePartitionComplete;
          final expected = isFullBurst
              ? RingOtaProtocol.responseBlockBurst
              : terminalCode;
          final wait = _registerResponseWait(
            expected,
            timeout: isFullBurst
                ? const Duration(seconds: 6)
                : const Duration(seconds: 6),
          );
          _emit(
            package,
            RingOtaTransferPhase.transferringPartition,
            acknowledgedBytes,
            partition.index,
          );
          for (final packet in packets) {
            _checkActive();
            final writeResult = await _transport.write(
              deviceId,
              RingOtaProtocol.serviceUuid,
              RingOtaProtocol.dataCharacteristicUuid,
              packet,
              withoutResponse: true,
            );
            if (writeResult case Err(:final error)) {
              _failResponseWait(error);
              _abort(error);
            }
            _checkActive();
          }
          await _awaitRegistered(wait);
          if (isFullBurst && !endsPartition) {
            await Future<void>.delayed(Duration.zero);
            _checkActive();
          }
          acknowledgedBytes += offset - burstStart;
          if (!isFullBurst) terminalReceived = true;
          _emit(
            package,
            terminalReceived
                ? RingOtaTransferPhase.awaitingPartitionComplete
                : RingOtaTransferPhase.transferringPartition,
            acknowledgedBytes,
            partition.index,
          );
        }
        if (!terminalReceived) {
          _emit(
            package,
            RingOtaTransferPhase.awaitingPartitionComplete,
            acknowledgedBytes,
            partition.index,
          );
          final isLast = partition.index == package.partitions.length - 1;
          await _waitForResponse(
            isLast
                ? RingOtaProtocol.responseOtaComplete
                : RingOtaProtocol.responsePartitionComplete,
            const Duration(seconds: 6),
          );
          _allowBufferedTerminal = false;
        }
      }

      _emit(
        package,
        RingOtaTransferPhase.bootloaderComplete,
        acknowledgedBytes,
      );
      _emit(package, RingOtaTransferPhase.rebooting, acknowledgedBytes);
      await _sendControl(
        RingOtaProtocol.delayedRebootCommand(),
        RingOtaProtocol.responseReboot,
      );
      final disconnectResult = await _transport.disconnect(deviceId);
      _requiresReconnect = true;
      _unwrap(disconnectResult);
      return Result.ok(
        RingOtaTransferResult(
          targetFirmwareVersion: package.firmwareVersion,
          partitionCount: package.partitions.length,
          acknowledgedBytes: acknowledgedBytes,
          rebootAcknowledged: true,
        ),
      );
    } on _RingOtaAbort catch (abort) {
      _emit(
        package,
        abort.failure.code == BleFailureCode.cancelled
            ? RingOtaTransferPhase.cancelled
            : RingOtaTransferPhase.failed,
        acknowledgedBytes,
      );
      return Result.err(abort.failure);
    } finally {
      _pendingResponse = null;
      _allowBufferedTerminal = false;
      _transferBusy = false;
      _cancelRequested = false;
    }
  }

  /// 请求停止当前单轮传输；不会伪装为成功或递归启动恢复流程。
  void cancelTransfer() {
    if (!_transferBusy) return;
    _cancelRequested = true;
    _requiresReconnect = true;
    _failResponseWait(_cancelledFailure());
  }

  @override
  Future<Result<void, BleFailure>> disconnect() async {
    _requiresReconnect = true;
    _failResponseWait(
      const BleFailure(
        code: BleFailureCode.connectionFailed,
        message: 'OTA session disconnected by caller',
      ),
    );
    return _transport.disconnect(deviceId);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelRequested = true;
    _failResponseWait(_disposedFailure());
    await _cancelSubscriptions();
    await _snapshots.close();
  }

  Future<void> _sendControl(Uint8List command, int expectedResponse) async {
    _checkActive();
    if (_responseQueue.isNotEmpty || _pendingResponse != null) {
      _abort(
        const BleFailure(
          code: BleFailureCode.protocolError,
          message: 'Unexpected buffered OTA response before control command',
        ),
      );
    }
    final wait = _registerResponseWait(
      expectedResponse,
      timeout: const Duration(seconds: 3),
    );
    final writeResult = await _transport.write(
      deviceId,
      RingOtaProtocol.serviceUuid,
      RingOtaProtocol.commandCharacteristicUuid,
      command,
    );
    if (writeResult case Err(:final error)) {
      _failResponseWait(error);
      _abort(error);
    }
    await _awaitRegistered(wait);
  }

  Future<void> _waitForResponse(int expected, Duration timeout) async {
    final wait = _registerResponseWait(expected, timeout: timeout);
    await _awaitRegistered(wait);
  }

  _PendingOtaResponse _registerResponseWait(
    int expected, {
    required Duration timeout,
  }) {
    _checkActive();
    if (_pendingResponse != null) {
      _abort(
        const BleFailure(
          code: BleFailureCode.busy,
          message: 'Another OTA response is already pending',
        ),
      );
    }
    final pending = _PendingOtaResponse(expected: expected, timeout: timeout);
    if (_responseQueue.isNotEmpty) {
      pending.complete(_responseQueue.removeFirst());
    } else {
      _pendingResponse = pending;
    }
    return pending;
  }

  Future<void> _awaitRegistered(_PendingOtaResponse pending) async {
    final result = await pending.future.timeout(
      pending.timeout,
      onTimeout: () {
        if (identical(_pendingResponse, pending)) _pendingResponse = null;
        _requiresReconnect = true;
        return const Result.err(
          BleFailure(
            code: BleFailureCode.timeout,
            message: 'OTA response timed out',
          ),
        );
      },
    );
    if (identical(_pendingResponse, pending)) _pendingResponse = null;
    final response = _unwrap(result);
    if (response.code != pending.expected) {
      _requiresReconnect = true;
      _abort(
        BleFailure(
          code: BleFailureCode.protocolError,
          message:
              'Unexpected OTA response 0x${response.code.toRadixString(16)}, expected 0x${pending.expected.toRadixString(16)}',
        ),
      );
    }
  }

  void _handleResponseValue(Uint8List value) {
    if (_disposed) return;
    final result = RingOtaProtocol.parseResponse(value);
    final pending = _pendingResponse;
    if (pending != null) {
      _pendingResponse = null;
      if (result case Ok(:final value) when value.code != pending.expected) {
        final failure = BleFailure(
          code: BleFailureCode.protocolError,
          message:
              'Unexpected OTA response 0x${value.code.toRadixString(16)}, expected 0x${pending.expected.toRadixString(16)}',
        );
        _requiresReconnect = true;
        _streamFailure = failure;
        pending.complete(Result.err(failure));
      } else {
        pending.complete(result);
      }
    } else if (_allowBufferedTerminal) {
      _responseQueue.add(result);
    } else {
      _failResponseWait(
        const BleFailure(
          code: BleFailureCode.protocolError,
          message: 'Unexpected OTA response without an active wait',
        ),
      );
    }
  }

  void _handleStreamError(Object error) {
    _failResponseWait(
      BleFailure(
        code: BleFailureCode.connectionFailed,
        message: 'OTA BLE stream failed',
        cause: error,
      ),
    );
  }

  void _failResponseWait(BleFailure failure) {
    _requiresReconnect = true;
    _streamFailure = failure;
    final pending = _pendingResponse;
    _pendingResponse = null;
    pending?.complete(Result.err(failure));
  }

  void _checkActive() {
    if (_disposed) _abort(_disposedFailure());
    if (_cancelRequested) _abort(_cancelledFailure());
    if (_streamFailure != null) _abort(_streamFailure!);
  }

  void _checkInitializationActive() {
    if (_disposed) _abort(_disposedFailure());
    if (_streamFailure != null) _abort(_streamFailure!);
  }

  T _unwrap<T>(Result<T, BleFailure> result) {
    return result.match(ok: (value) => value, err: _abort);
  }

  Never _abort(BleFailure failure) => throw _RingOtaAbort(failure);

  void _emit(
    RingOtaPackage package,
    RingOtaTransferPhase phase,
    int acknowledgedBytes, [
    int? partitionIndex,
  ]) {
    if (_snapshots.isClosed) return;
    _snapshots.add(
      RingOtaTransferSnapshot(
        phase: phase,
        partitionIndex: partitionIndex,
        partitionCount: package.partitions.length,
        acknowledgedBytes: acknowledgedBytes,
        totalBytes: package.totalSize,
      ),
    );
  }

  bool _containsRequiredGatt(List<BleDiscoveredService> services) {
    for (final service in services) {
      if (!_uuidMatches(service.uuid, RingOtaProtocol.serviceUuid)) continue;
      bool has(String uuid, bool Function(BleDiscoveredCharacteristic) test) =>
          service.characteristics.any(
            (item) => _uuidMatches(item.uuid, uuid) && test(item),
          );
      return has(
            RingOtaProtocol.commandCharacteristicUuid,
            (item) => item.canWrite,
          ) &&
          has(
            RingOtaProtocol.responseCharacteristicUuid,
            (item) => item.canNotify,
          ) &&
          has(
            RingOtaProtocol.dataCharacteristicUuid,
            (item) => item.canWriteWithoutResponse,
          );
    }
    return false;
  }

  bool _uuidMatches(String left, String right) =>
      left.replaceAll('-', '').toLowerCase() ==
      right.replaceAll('-', '').toLowerCase();

  Future<void> _cancelSubscriptions() async {
    final subscriptions = List<StreamSubscription>.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }

  BleFailure _disposedFailure() => const BleFailure(
    code: BleFailureCode.connectionFailed,
    message: 'OTA session is disposed',
  );

  BleFailure _cancelledFailure() => const BleFailure(
    code: BleFailureCode.cancelled,
    message: 'OTA transfer was cancelled',
  );

  BleFailure _reconnectFailure() => const BleFailure(
    code: BleFailureCode.connectionFailed,
    message: 'OTA session must reconnect before another transfer',
  );
}

class _PendingOtaResponse {
  _PendingOtaResponse({required this.expected, required this.timeout});

  final int expected;
  final Duration timeout;
  final _completer = Completer<Result<RingOtaResponse, BleFailure>>();

  Future<Result<RingOtaResponse, BleFailure>> get future => _completer.future;

  void complete(Result<RingOtaResponse, BleFailure> result) {
    if (!_completer.isCompleted) _completer.complete(result);
  }
}

class _RingOtaAbort implements Exception {
  const _RingOtaAbort(this.failure);

  final BleFailure failure;
}
