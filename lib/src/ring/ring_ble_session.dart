import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:common/common.dart';

import '../common/ble_failure.dart';
import '../common/hex_utils.dart';
import '../core/ble_scan_device.dart';
import '../core/ble_session.dart';
import '../core/ble_transport.dart';
import 'ring_models.dart';
import 'ring_protocol.dart';

/// 智能戒指已连接会话。
///
/// 负责 MTU 协商、服务发现、Notify 订阅、命令写入、响应等待、
/// 主动上报分发，以及 `0x010A`/`0x010B` 的 DONE 门控。
class RingBleSession implements BleSession {
  /// 创建智能戒指会话。
  ///
  /// [device] 为扫描到并已连接的设备；[transport] 为 BLE 传输层；
  /// [codec] 为协议帧编解码器，测试时可注入自定义实现。
  factory RingBleSession({
    required BleScanDevice device,
    required BleTransport transport,
    RingFrameCodec codec = const RingFrameCodec(),
  }) {
    return RingBleSession._(
      device,
      transport,
      codec,
      RingAdvertisement.fromScanDevice(device).valueOrNull,
    );
  }

  RingBleSession._(
    this._device,
    this._transport,
    this._codec,
    this._advertisement,
  );

  final BleScanDevice _device;
  final BleTransport _transport;
  final RingFrameCodec _codec;
  final RingAdvertisement? _advertisement;
  final List<StreamSubscription> _subscriptions = [];
  final Queue<_PendingFrame> _pendingFrames = Queue<_PendingFrame>();

  bool _initialized = false;
  bool _screenFlipBusy = false;
  bool _findRingBusy = false;
  bool _otaEntryBusy = false;
  Future<void> _customZikrTail = Future<void>.value();
  Completer<Result<RingOtaEntryState, BleFailure>>? _otaEntryOutcome;
  Completer<Result<RingScreenDirection, BleFailure>>? _screenFlipDone;
  Completer<Result<void, BleFailure>>? _findRingDone;

  final _logs = StreamController<RingFrameLog>.broadcast();
  final _errors = StreamController<BleFailure>.broadcast();
  final _battery = StreamController<RingBattery>.broadcast();
  final _deviceInfo = StreamController<RingDeviceInfo>.broadcast();
  final _time = StreamController<DateTime>.broadcast();
  final _sport = StreamController<RingRealtimeSport>.broadcast();
  final _buttonCount = StreamController<RingButtonCount>.broadcast();
  final _zikrDay = StreamController<RingZikrDay>.broadcast();
  final _zikrBatchEnd = StreamController<RingZikrBatchEnd>.broadcast();
  final _customZikrState = StreamController<RingCustomZikrState>.broadcast();
  final _customZikrEvent = StreamController<RingCustomZikrEvent>.broadcast();
  final _screenOffTime = StreamController<RingScreenOffTime>.broadcast();
  final _screenDirection = StreamController<RingScreenDirection>.broadcast();
  final _prayerReminders =
      StreamController<List<RingPrayerReminder>>.broadcast();
  final _actionState = StreamController<RingActionState>.broadcast();

  @override
  /// 平台设备标识。
  String get deviceId => _device.deviceId;

  /// 扫描阶段保存的设备信息。
  BleScanDevice get device => _device;

  /// 扫描阶段解析出的戒指厂商数据。
  ///
  /// 包含广播 MAC、固件版本、客户 id、机器 id、绑定能力和绑定状态等字段。
  /// 若该会话来自缓存设备或扫描结果未携带厂商数据，则为空。
  RingAdvertisement? get advertisement => _advertisement;

  /// 收发帧日志流，包含 TX/RX 完整 hex 和命令名。
  Stream<RingFrameLog> get logs => _logs.stream;

  /// 协议解析、设备错误帧或传输异常流。
  Stream<BleFailure> get errors => _errors.stream;

  /// 电量查询响应或电量变化主动上报流。
  Stream<RingBattery> get batteryStream => _battery.stream;

  /// 设备信息查询响应流。
  Stream<RingDeviceInfo> get deviceInfoStream => _deviceInfo.stream;

  /// 查询时间响应流。
  Stream<DateTime> get timeStream => _time.stream;

  /// 实时运动主动上报流。
  Stream<RingRealtimeSport> get sportStream => _sport.stream;

  /// 按键计数主动上报流。
  Stream<RingButtonCount> get buttonCountStream => _buttonCount.stream;

  /// 赞念分时段主动上报流。
  Stream<RingZikrDay> get zikrDayStream => _zikrDay.stream;

  /// `0x0306` 批次结束流；不代表 App 已完整收到本批次数据。
  Stream<RingZikrBatchEnd> get zikrBatchEndStream => _zikrBatchEnd.stream;

  /// `0x0111 op=2` 状态响应流。
  Stream<RingCustomZikrState> get customZikrStateStream =>
      _customZikrState.stream;

  /// `0x0307` 自定义赞念主动事件流。
  Stream<RingCustomZikrEvent> get customZikrEventStream =>
      _customZikrEvent.stream;

  /// 设备主动上报或设置后的息屏时间流。
  Stream<RingScreenOffTime> get screenOffTimeStream => _screenOffTime.stream;

  /// 屏幕方向查询、上电主动上报或翻转应答流。
  Stream<RingScreenDirection> get screenDirectionStream =>
      _screenDirection.stream;

  /// 查询到的诵经提醒表流。
  Stream<List<RingPrayerReminder>> get prayerRemindersStream =>
      _prayerReminders.stream;

  /// 屏幕翻转、寻找戒指等两段式命令状态流。
  Stream<RingActionState> get actionStateStream => _actionState.stream;

  @override
  /// 连接状态变化流。
  Stream<bool> get connectionStream => _transport.connectionStream(deviceId);

  @override
  /// 初始化会话。
  ///
  /// 连接后应调用一次：请求 MTU、发现 GATT 服务、订阅 Notify。
  Future<Result<void, BleFailure>> initialize() async {
    if (_initialized) return const Result.ok(null);

    _subscriptions.add(
      _transport
          .valueStream(deviceId, RingProtocol.notifyCharacteristicUuid)
          .listen(_handleNotifyValue, onError: _handleStreamError),
    );
    _subscriptions.add(
      connectionStream.listen((connected) {
        if (!connected) {
          if (_otaEntryBusy && _otaEntryOutcome?.isCompleted == false) {
            _otaEntryOutcome?.complete(
              const Result.ok(RingOtaEntryState.deviceDisconnected),
            );
          }
          _failPending(
            const BleFailure(
              code: BleFailureCode.connectionFailed,
              message: 'BLE device disconnected',
            ),
            exceptCommandValue: _otaEntryBusy
                ? RingCommand.otaEnter.value
                : null,
          );
        }
      }),
    );

    await _transport.requestMtu(deviceId, RingProtocol.requestedMtu);
    final servicesResult = await _transport.discoverServices(deviceId);
    if (servicesResult case Err(:final error)) {
      return Result.err(error);
    }
    final services = servicesResult.valueOrNull ?? [];
    if (!_containsRingCharacteristics(services)) {
      return const Result.err(
        BleFailure(
          code: BleFailureCode.serviceNotFound,
          message: 'Ring GATT service or characteristics were not found',
        ),
      );
    }

    final subscribeResult = await _transport.subscribeNotifications(
      deviceId,
      RingProtocol.serviceUuid,
      RingProtocol.notifyCharacteristicUuid,
    );
    if (subscribeResult.isErr) {
      return Result.err(subscribeResult.failureOrNull!);
    }
    _initialized = true;
    return const Result.ok(null);
  }

  /// 发送 PING 联调命令。
  ///
  /// [payload] 为任意测试字节，设备会原样回显。
  Future<Result<Uint8List, BleFailure>> ping(List<int> payload) async {
    final result = await _sendAndWait(
      RingCommand.ping,
      payload: Uint8List.fromList(payload),
    );
    return result.match(
      ok: (value) => Result.ok(value.payload),
      err: (err) => Result.err(err),
    );
  }

  /// 查询设备信息。
  Future<Result<RingDeviceInfo, BleFailure>> queryDeviceInfo() async {
    final result = await _sendAndWait(RingCommand.deviceInfo);
    return _mapPayload(result, RingDeviceInfo.fromPayload);
  }

  /// 查询当前电量。
  Future<Result<RingBattery, BleFailure>> queryBattery() async {
    final result = await _sendAndWait(RingCommand.battery);
    return _mapPayload(result, RingBattery.fromPayload);
  }

  /// 查询当前按键计数。
  Future<Result<RingButtonCount, BleFailure>> queryButtonCount() async {
    final result = await _sendAndWait(RingCommand.buttonCountQuery);
    return _mapPayload(result, RingButtonCount.fromPayload);
  }

  /// 进入自定义赞念模式并把计数从 0 开始。
  ///
  /// [target] 必须为 1~9999。成功响应必须精确为单字节 `0x01`。
  Future<Result<void, BleFailure>> enterCustomZikr(int target) {
    if (target < 1 || target > 9999) {
      return Future.value(
        const Result.err(
          BleFailure(
            code: BleFailureCode.protocolError,
            message: 'Custom zikr target must be between 1 and 9999',
          ),
        ),
      );
    }
    return _serializeCustomZikr(() async {
      final result = await _sendAndWait(
        RingCommand.customZikrMode,
        payload: Uint8List.fromList([1, target & 0xFF, target >> 8]),
        predicate: _payloadIs(1),
      );
      return _expectExactStatus(result, 1);
    });
  }

  /// 显式退出自定义赞念模式并清除设备状态。
  Future<Result<void, BleFailure>> exitCustomZikr() {
    return _serializeCustomZikr(() async {
      final result = await _sendAndWait(
        RingCommand.customZikrMode,
        payload: Uint8List.fromList([0]),
        predicate: _payloadIs(1),
      );
      return _expectExactStatus(result, 1);
    });
  }

  /// 查询戒指当前自定义赞念模式状态。
  ///
  /// 查询响应必须精确为 `[active, count u16 LE, target u16 LE]` 五字节。
  Future<Result<RingCustomZikrState, BleFailure>> queryCustomZikr() {
    return _serializeCustomZikr(() async {
      final result = await _sendAndWait(
        RingCommand.customZikrMode,
        payload: Uint8List.fromList([2]),
        predicate: (frame) => frame.payload.length == 5,
      );
      return _mapPayload(result, RingCustomZikrState.fromPayload);
    });
  }

  /// 开关实时运动上报。
  ///
  /// [enabled] 为 true 时开启约 2 秒一次的运动上报，false 时关闭。
  Future<Result<void, BleFailure>> setRealtimeSportEnabled(bool enabled) async {
    final result = await _sendAndWait(
      RingCommand.sportRealtimeSwitch,
      payload: Uint8List.fromList([enabled ? 1 : 2]),
    );
    return _expectStatus(result, enabled ? 1 : 2);
  }

  /// 软断开蓝牙。
  ///
  /// 设备会先响应受理，再在约 300ms 后断开，用于 App 退出前释放链路。
  Future<Result<void, BleFailure>> softDisconnect() async {
    final result = await _sendAndWait(RingCommand.softDisconnect);
    final status = _expectStatus(result, 1);
    if (status.isOk) {
      unawaited(_transport.disconnect(deviceId));
    }
    return status;
  }

  /// 设置设备时间。
  ///
  /// [dateTime] 会被编码成协议要求的 Unix 秒和时区字段。
  Future<Result<void, BleFailure>> setTime(DateTime dateTime) async {
    final result = await _sendAndWait(
      RingCommand.setTime,
      payload: ringTimePayload(dateTime),
    );
    return _expectStatus(result, 1);
  }

  /// 查询设备当前时间。
  Future<Result<DateTime, BleFailure>> queryTime() async {
    final result = await _sendAndWait(RingCommand.queryTime);
    return _mapPayload(result, ringParseTimePayload);
  }

  /// 查询应用固件与 OTA Bootloader 信息。
  Future<Result<RingOtaInfo, BleFailure>> queryOtaInfo() async {
    final result = await _sendAndWait(RingCommand.otaInfo);
    return _mapPayload(result, RingOtaInfo.fromPayload);
  }

  /// 请求设备进入 OTA 模式，并等待设备主动断开业务链路。
  ///
  /// 收到精确 `[0x01]` 后最多等待 5 秒。超时只返回
  /// [RingOtaEntryState.disconnectTimedOut]，不主动断开或扫描，由上层决定下一步。
  Future<Result<RingOtaEntryState, BleFailure>> enterOtaMode() async {
    if (_otaEntryBusy) {
      return const Result.err(
        BleFailure(
          code: BleFailureCode.busy,
          message: 'OTA mode entry is already in progress',
        ),
      );
    }
    _otaEntryBusy = true;
    final outcome = Completer<Result<RingOtaEntryState, BleFailure>>();
    _otaEntryOutcome = outcome;
    try {
      final result = await _sendAndWait(RingCommand.otaEnter);
      if (result case Err(:final error)) {
        // 戒指进入 Bootloader 时可能先断开，再使 Android 的 GATT 写回调失败。
        // 此时断链已由连接流确认，继续由上层扫描 OTA 广播验证目标设备。
        if (outcome.isCompleted) return await outcome.future;
        return Result.err(error);
      }
      final payload = result.valueOrNull!.payload;
      if (payload.length != 1 || payload[0] != 0x01) {
        return const Result.err(
          BleFailure(
            code: BleFailureCode.protocolError,
            message: 'Unexpected OTA mode entry status',
          ),
        );
      }
      return await outcome.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => const Result.ok(RingOtaEntryState.disconnectTimedOut),
      );
    } finally {
      _otaEntryBusy = false;
      _otaEntryOutcome = null;
    }
  }

  /// 翻转屏幕方向。
  ///
  /// [flipped] 为 null 时按固件 toggle 当前方向；true 表示翻转 180°；
  /// false 表示恢复正常方向。该命令会等待设备返回 DONE 后才完成。
  Future<Result<RingScreenDirection, BleFailure>> flipScreen({
    bool? flipped,
  }) async {
    if (_screenFlipBusy) {
      final failure = const BleFailure(
        code: BleFailureCode.busy,
        message: 'Screen flip is waiting for DONE',
      );
      _emitActionFailure(RingCommand.screenFlip, failure);
      return Result.err(failure);
    }
    _screenFlipBusy = true;
    final done = Completer<Result<RingScreenDirection, BleFailure>>();
    _screenFlipDone = done;
    _emitAction(
      RingCommand.screenFlip,
      RingActionPhase.sending,
      message: 'Screen flip command sent, waiting for accepted',
    );
    final payload = flipped == null ? const <int>[] : [flipped ? 1 : 0];
    final accepted = await _sendAndWait(
      RingCommand.screenFlip,
      payload: Uint8List.fromList(payload),
      predicate: _payloadStatusIn({1, 2}),
    );
    if (accepted case Err(:final error)) {
      _screenFlipBusy = false;
      if (_screenFlipDone == done) {
        _screenFlipDone = null;
      }
      _emitActionFailure(RingCommand.screenFlip, error);
      return Result.err(error);
    }
    return done.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        final failure = const BleFailure(
          code: BleFailureCode.timeout,
          message: 'Screen flip DONE timed out',
        );
        _screenFlipBusy = false;
        if (_screenFlipDone == done) {
          _screenFlipDone = null;
        }
        _emitActionFailure(RingCommand.screenFlip, failure);
        return Result.err(failure);
      },
    );
  }

  /// 查询当前屏幕方向。
  ///
  /// 返回 `0x010E` 的 1 字节方向值，`0` 为正常，`1` 为翻转 180°。
  Future<Result<RingScreenDirection, BleFailure>> queryScreenDirection() async {
    final result = await _sendAndWait(RingCommand.screenDirection);
    return _mapPayload(result, _parseScreenDirectionPayload);
  }

  /// 开始寻找戒指。
  ///
  /// 戒指会振动并显示图标；方法会等待 App 停止、戒指按键停止或 10 秒超时
  /// 后设备返回 DONE。
  Future<Result<void, BleFailure>> startFindRing() async {
    if (_findRingBusy) {
      final failure = const BleFailure(
        code: BleFailureCode.busy,
        message: 'Find ring is waiting for DONE',
      );
      _emitActionFailure(RingCommand.findRing, failure);
      return Result.err(failure);
    }
    _findRingBusy = true;
    final done = Completer<Result<void, BleFailure>>();
    _findRingDone = done;
    _emitAction(
      RingCommand.findRing,
      RingActionPhase.sending,
      message: 'Find ring command sent, waiting for accepted',
    );
    final accepted = await _sendAndWait(
      RingCommand.findRing,
      payload: Uint8List.fromList([1]),
      predicate: _payloadStatusIn({1, 2}),
    );
    if (accepted case Err(:final error)) {
      _findRingBusy = false;
      if (_findRingDone == done) {
        _findRingDone = null;
      }
      _emitActionFailure(RingCommand.findRing, error);
      return Result.err(error);
    }
    return done.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        final failure = const BleFailure(
          code: BleFailureCode.timeout,
          message: 'Find ring DONE timed out',
        );
        _findRingBusy = false;
        if (_findRingDone == done) {
          _findRingDone = null;
        }
        _emitActionFailure(RingCommand.findRing, failure);
        return Result.err(failure);
      },
    );
  }

  /// 停止寻找戒指。
  ///
  /// 若设备本就不在寻找，也会按协议立即返回 DONE。
  Future<Result<void, BleFailure>> stopFindRing() async {
    _emitAction(
      RingCommand.findRing,
      RingActionPhase.sending,
      message: 'Stop find ring command sent, waiting for DONE',
    );
    final result = await _sendAndWait(
      RingCommand.findRing,
      payload: Uint8List.fromList([2]),
      predicate: _payloadIs(2),
    );
    return result.match(
      ok: (_) => const Result.ok(null),
      err: (err) {
        _emitActionFailure(RingCommand.findRing, err);
        return Result.err(err);
      },
    );
  }

  /// 确认并清除某天历史赞念数据。
  ///
  /// [date] 为需要清除的公历日期；当天数据传入后设备会忽略。
  Future<Result<void, BleFailure>> confirmZikrHistoryDay(DateTime date) async {
    final result = await _sendAndWait(
      RingCommand.clearZikrHistoryDay,
      payload: Uint8List.fromList([date.year - 2000, date.month, date.day]),
    );
    return _expectStatus(result, 1);
  }

  /// 设置息屏/进睡时间。
  ///
  /// [seconds] 只能是 10、20、30、40、50、60。
  Future<Result<void, BleFailure>> setScreenOffTime(int seconds) async {
    if (seconds < 10 || seconds > 60 || seconds % 10 != 0) {
      return const Result.err(
        BleFailure(
          code: BleFailureCode.protocolError,
          message: 'Screen off seconds must be 10,20,30,40,50,60',
        ),
      );
    }
    final result = await _sendAndWait(
      RingCommand.screenOffTime,
      payload: Uint8List.fromList([seconds]),
      predicate: _payloadIs(1),
    );
    return _expectStatus(result, 1);
  }

  /// 查询设备保存的诵经提醒表。
  ///
  /// 最多返回 8 条提醒；当前固件仅支持读写和持久化，尚未触发到点提醒。
  // Future<Result<List<RingPrayerReminder>>> queryPrayerReminders() async {
  //   final result = await _sendAndWait(RingCommand.prayerReminderQuery);
  //   return _mapPayload(result, RingPrayerReminder.listFromPayload);
  // }

  /// 覆盖设置设备诵经提醒表。
  ///
  /// [reminders] 最多 8 条；每条包含开关、小时、分钟和星期重复位图。
  // Future<Result<void,BleFailure>> setPrayerReminders(
  //   List<RingPrayerReminder> reminders,
  // ) async {
  //   final payload = RingPrayerReminder.listToPayload(reminders);
  //   if (payload case Failure<Uint8List>(:final failure)) {
  //     return Result.failure(failure);
  //   }
  //   final result = await _sendAndWait(
  //     RingCommand.prayerReminderSet,
  //     payload: (payload as Success<Uint8List>).value,
  //     predicate: _payloadIs(1),
  //   );
  //   return _expectStatus(result, 1);
  // }

  @override
  /// 主动断开当前设备。
  Future<Result<void, BleFailure>> disconnect() {
    return _transport.disconnect(deviceId);
  }

  @override
  /// 释放会话资源。
  ///
  /// 会取消所有 stream 订阅、关闭控制器，并让等待中的命令失败返回。
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    const disposedFailure = BleFailure(
      code: BleFailureCode.connectionFailed,
      message: 'Ring session disposed',
    );
    if (_otaEntryOutcome?.isCompleted == false) {
      _otaEntryOutcome?.complete(const Result.err(disposedFailure));
    }
    _failPending(disposedFailure);
    await _logs.close();
    await _errors.close();
    await _battery.close();
    await _deviceInfo.close();
    await _time.close();
    await _sport.close();
    await _buttonCount.close();
    await _zikrDay.close();
    await _zikrBatchEnd.close();
    await _customZikrState.close();
    await _customZikrEvent.close();
    await _screenOffTime.close();
    await _screenDirection.close();
    await _prayerReminders.close();
    await _actionState.close();
  }

  Future<Result<RingFrame, BleFailure>> _sendAndWait(
    RingCommand command, {
    Uint8List? payload,
    bool Function(RingFrame frame)? predicate,
  }) async {
    final frame = _codec.encode(command, payload ?? Uint8List(0));
    final pending = _PendingFrame(
      commandValue: command.value,
      predicate: predicate ?? (_) => true,
    );
    _pendingFrames.add(pending);
    _logs.add(
      RingFrameLog(
        direction: 'TX',
        timestamp: DateTime.now(),
        commandValue: command.value,
        command: command,
        hex: bytesToHex(frame),
      ),
    );

    final writeResult = await _transport.write(
      deviceId,
      RingProtocol.serviceUuid,
      RingProtocol.writeCharacteristicUuid,
      frame,
    );
    if (writeResult case Err(:final error)) {
      _pendingFrames.remove(pending);
      pending.complete(Result.err(error));
    }

    return pending.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pendingFrames.remove(pending);
        return Result.err(
          BleFailure(
            code: BleFailureCode.timeout,
            message: '${command.label} response timed out',
          ),
        );
      },
    );
  }

  /// 串行化共用 `0x0111` 命令字的操作，避免并发请求发生应答错配。
  ///
  /// 协议没有 transaction id；超时后的迟到单字节 ACK 不能用于推断后续
  /// 操作结果，调用方应先通过精确五字节查询对账。
  Future<Result<T, BleFailure>> _serializeCustomZikr<T>(
    Future<Result<T, BleFailure>> Function() operation,
  ) {
    final previous = _customZikrTail;
    final completer = Completer<Result<T, BleFailure>>();
    _customZikrTail = () async {
      await previous;
      try {
        completer.complete(await operation());
      } on Object catch (error) {
        if (error is BleFailure) {
          completer.complete(Result.err(error));
        } else {
          completer.complete(
            Result.err(
              BleFailure(
                code: BleFailureCode.protocolError,
                message: 'Custom zikr operation failed',
                cause: error,
              ),
            ),
          );
        }
        // Keep the serialized tail usable after a failed operation.
      }
    }();
    return completer.future;
  }

  Result<T, BleFailure> _mapPayload<T>(
    Result<RingFrame, BleFailure> result,
    T Function(Uint8List payload) mapper,
  ) {
    return result.match(
      ok: (value) {
        return _guard(() => mapper(value.payload));
      },
      err: (err) => Result.err(err),
    );
  }

  Result<T, BleFailure> _guard<T>(T Function() action) {
    try {
      return Result.ok(action());
    } catch (error) {
      return Result.err(
        BleFailure(
          code: BleFailureCode.protocolError,
          message: 'Unable to parse ring payload',
          cause: error,
        ),
      );
    }
  }

  Result<void, BleFailure> _expectStatus(
    Result<RingFrame, BleFailure> result,
    int status,
  ) {
    return result.match(
      ok: (value) {
        if (value.payload.isNotEmpty && value.payload[0] == status) {
          return const Result.ok(null);
        }
        return const Result.err(
          BleFailure(
            code: BleFailureCode.protocolError,
            message: 'Unexpected ring command status',
          ),
        );
      },
      err: (err) => Result.err(err),
    );
  }

  Result<void, BleFailure> _expectExactStatus(
    Result<RingFrame, BleFailure> result,
    int status,
  ) {
    return result.match(
      ok: (value) => value.payload.length == 1 && value.payload[0] == status
          ? const Result.ok(null)
          : const Result.err(
              BleFailure(
                code: BleFailureCode.protocolError,
                message: 'Unexpected ring command status',
              ),
            ),
      err: (err) => Result.err(err),
    );
  }

  void _handleNotifyValue(Uint8List value) {
    final result = _codec.decode(value);
    result.match(
      ok: (value) {
        _logs.add(
          RingFrameLog(
            direction: 'RX',
            timestamp: DateTime.now(),
            commandValue: value.commandValue,
            command: value.command,
            hex: bytesToHex(
              _codec.encodeValue(value.commandValue, value.payload),
            ),
            error: value.deviceError,
            description: value.deviceError?.message,
          ),
        );
        _handleFrame(value);
      },
      err: (err) {
        _errors.add(err);
      },
    );
    // switch (result) {
    //   case Ok<RingFrame, void>(:final value):
    //     _logs.add(
    //       RingFrameLog(
    //         direction: 'RX',
    //         timestamp: DateTime.now(),
    //         commandValue: value.commandValue,
    //         command: value.command,
    //         hex: bytesToHex(
    //           _codec.encodeValue(value.commandValue, value.payload),
    //         ),
    //         error: value.deviceError,
    //         description: value.deviceError?.message,
    //       ),
    //     );
    //     _handleFrame(value);
    //   case Err<void, RingFrame>(:final error):
    //     _errors.add(error);
    // }
  }

  void _handleFrame(RingFrame frame) {
    if (frame.isDeviceError) {
      final error = frame.deviceError;
      final failure = BleFailure(
        code: BleFailureCode.deviceError,
        message: error?.message ?? 'Ring device returned an error',
        cause: error,
      );
      _failTwoStageCommand(frame.command, failure);
      _completePending(frame, Result.err(failure));
      _errors.add(failure);
      return;
    }

    _dispatchBusinessEvent(frame);
    _completePending(frame, Result.ok(frame));
  }

  void _dispatchBusinessEvent(RingFrame frame) {
    try {
      switch (frame.command) {
        case RingCommand.deviceInfo:
          if (frame.payload.length == 52) {
            _deviceInfo.add(RingDeviceInfo.fromPayload(frame.payload));
          }
        case RingCommand.battery || RingCommand.batteryReport:
          if (frame.payload.length >= 2) {
            _battery.add(RingBattery.fromPayload(frame.payload));
          }
        case RingCommand.queryTime:
          if (frame.payload.length >= 7) {
            _time.add(ringParseTimePayload(frame.payload));
          }
        case RingCommand.sportRealtimeReport:
          _sport.add(RingRealtimeSport.fromPayload(frame.payload));
        case RingCommand.buttonCountQuery || RingCommand.buttonCountReport:
          _buttonCount.add(RingButtonCount.fromPayload(frame.payload));
        case RingCommand.zikrHourlyReport:
          if (frame.payload.length == 52) {
            _zikrDay.add(RingZikrDay.fromPayload(frame.payload));
          } else if (frame.payload.length == 13) {
            _zikrBatchEnd.add(RingZikrBatchEnd.fromPayload(frame.payload));
          } else {
            throw FormatException(
              'Zikr 0x0306 payload must be 52 or 13 bytes, got ${frame.payload.length}',
            );
          }
        case RingCommand.customZikrMode:
          if (frame.payload.length == 5) {
            _customZikrState.add(
              RingCustomZikrState.fromPayload(frame.payload),
            );
          }
        case RingCommand.customZikrReport:
          _customZikrEvent.add(RingCustomZikrEvent.fromPayload(frame.payload));
        case RingCommand.screenOffTime:
          if (frame.payload.length == 1 && frame.payload[0] >= 10) {
            _screenOffTime.add(RingScreenOffTime(frame.payload[0]));
          }
        case RingCommand.screenFlip:
          if (frame.payload.length >= 2) {
            final direction = RingScreenDirection.fromValue(frame.payload[1]);
            _screenDirection.add(direction);
            if (frame.payload[0] == 1) {
              _emitAction(
                RingCommand.screenFlip,
                RingActionPhase.accepted,
                status: 1,
                screenDirection: direction,
                message:
                    'Screen flip accepted, direction is ${direction.label}',
              );
            } else if (frame.payload[0] == 2) {
              _screenFlipBusy = false;
              _emitAction(
                RingCommand.screenFlip,
                RingActionPhase.done,
                status: 2,
                screenDirection: direction,
                message: 'Screen flip DONE, direction is ${direction.label}',
              );
              _screenFlipDone?.complete(Result.ok(direction));
              _screenFlipDone = null;
            }
          }
        case RingCommand.screenDirection:
          if (frame.payload.length == 1) {
            _screenDirection.add(
              RingScreenDirection.fromValue(frame.payload[0]),
            );
          }
        case RingCommand.prayerReminderQuery:
        // _prayerReminders.add(
        //   RingPrayerReminder.listFromPayload(frame.payload),
        // );
        case RingCommand.findRing:
          if (frame.payload.length == 1) {
            if (frame.payload[0] == 1) {
              _emitAction(
                RingCommand.findRing,
                RingActionPhase.accepted,
                status: 1,
                message: 'Find ring accepted, waiting for DONE',
              );
            } else if (frame.payload[0] == 2) {
              _findRingBusy = false;
              _emitAction(
                RingCommand.findRing,
                RingActionPhase.done,
                status: 2,
                message: 'Find ring DONE received',
              );
              _findRingDone?.complete(const Result.ok(null));
              _findRingDone = null;
            }
          }
        case RingCommand.ping ||
            RingCommand.sportRealtimeSwitch ||
            RingCommand.softDisconnect ||
            RingCommand.setTime ||
            RingCommand.clearZikrHistoryDay ||
            RingCommand.prayerReminderSet ||
            RingCommand.otaEnter ||
            RingCommand.otaInfo:
        case null:
      }
    } catch (error) {
      _errors.add(
        BleFailure(
          code: BleFailureCode.protocolError,
          message: 'Unable to dispatch ring frame',
          cause: error,
        ),
      );
    }
  }

  void _emitAction(
    RingCommand command,
    RingActionPhase phase, {
    int? status,
    RingScreenDirection? screenDirection,
    String? message,
    BleFailure? failure,
  }) {
    _actionState.add(
      RingActionState(
        command: command,
        phase: phase,
        status: status,
        screenDirection: screenDirection,
        message: message,
        failure: failure,
      ),
    );
  }

  void _emitActionFailure(RingCommand command, BleFailure failure) {
    _emitAction(
      command,
      RingActionPhase.failed,
      message: failure.message,
      failure: failure,
    );
  }

  void _failTwoStageCommand(RingCommand? command, BleFailure failure) {
    switch (command) {
      case RingCommand.screenFlip:
        if (_screenFlipBusy) {
          _screenFlipBusy = false;
          if (_screenFlipDone?.isCompleted == false) {
            _screenFlipDone?.complete(Result.err(failure));
          }
          _screenFlipDone = null;
          _emitActionFailure(RingCommand.screenFlip, failure);
        }
      case RingCommand.findRing:
        if (_findRingBusy) {
          _findRingBusy = false;
          if (_findRingDone?.isCompleted == false) {
            _findRingDone?.complete(Result.err(failure));
          }
          _findRingDone = null;
          _emitActionFailure(RingCommand.findRing, failure);
        }
      case _:
    }
  }

  void _failActiveActions(BleFailure failure) {
    if (_screenFlipBusy) {
      _emitActionFailure(RingCommand.screenFlip, failure);
    }
    if (_findRingBusy) {
      _emitActionFailure(RingCommand.findRing, failure);
    }
  }

  void _completePending(RingFrame frame, Result<RingFrame, BleFailure> result) {
    // start 与 stop 共用 0x010B；极早收到 DONE 时，两个 pending 都属于同一
    // 次停止动作，不能只完成队首 start pending 而让 stop 等到超时。
    if (frame.command == RingCommand.findRing &&
        result.isOk &&
        frame.payload.length == 1 &&
        frame.payload[0] == 2) {
      final matches = _pendingFrames
          .where(
            (pending) =>
                pending.commandValue == frame.commandValue &&
                pending.predicate(frame),
          )
          .toList();
      for (final pending in matches) {
        _pendingFrames.remove(pending);
        pending.complete(result);
      }
      return;
    }
    _PendingFrame? match;
    for (final pending in _pendingFrames) {
      if (pending.commandValue == frame.commandValue &&
          (result.isErr || pending.predicate(frame))) {
        match = pending;
        break;
      }
    }
    if (match == null) return;
    _pendingFrames.remove(match);
    match.complete(result);
  }

  void _failPending(BleFailure failure, {int? exceptCommandValue}) {
    _failActiveActions(failure);
    final failed = _pendingFrames
        .where((pending) => pending.commandValue != exceptCommandValue)
        .toList();
    for (final pending in failed) {
      _pendingFrames.remove(pending);
      pending.complete(Result.err(failure));
    }
    if (_screenFlipDone?.isCompleted == false) {
      _screenFlipDone?.complete(Result.err(failure));
    }
    if (_findRingDone?.isCompleted == false) {
      _findRingDone?.complete(Result.err(failure));
    }
    _screenFlipBusy = false;
    _findRingBusy = false;
  }

  void _handleStreamError(Object error) {
    _errors.add(
      BleFailure(
        code: BleFailureCode.unknown,
        message: 'BLE notification stream error',
        cause: error,
      ),
    );
  }

  bool _containsRingCharacteristics(List<BleDiscoveredService> services) {
    for (final service in services) {
      if (!_uuidMatches(service.uuid, RingProtocol.serviceUuid)) continue;
      final hasWrite = service.characteristics.any(
        (item) => _uuidMatches(item.uuid, RingProtocol.writeCharacteristicUuid),
      );
      final hasNotify = service.characteristics.any(
        (item) =>
            _uuidMatches(item.uuid, RingProtocol.notifyCharacteristicUuid),
      );
      return hasWrite && hasNotify;
    }
    return false;
  }

  bool _uuidMatches(String uuid, String shortUuid) {
    final normalized = uuid.toLowerCase();
    final short = shortUuid.toLowerCase();
    return normalized == short || normalized.startsWith('0000$short-');
  }

  bool Function(RingFrame frame) _payloadIs(int status) {
    return (frame) => frame.payload.length == 1 && frame.payload[0] == status;
  }

  bool Function(RingFrame frame) _payloadStatusIn(Set<int> statuses) {
    return (frame) =>
        frame.payload.isNotEmpty && statuses.contains(frame.payload[0]);
  }

  RingScreenDirection _parseScreenDirectionPayload(Uint8List payload) {
    if (payload.length != 1) {
      throw const FormatException('Screen direction payload must be 1 byte');
    }
    return RingScreenDirection.fromValue(payload[0]);
  }
}

/// 进入 OTA 模式命令完成后的业务链路状态。
enum RingOtaEntryState {
  /// 设备已按协议主动断开业务链路。
  deviceDisconnected,

  /// 收到命令确认后 5 秒仍未收到断链事件，由上层决定是否主动断开。
  disconnectTimedOut,
}

class _PendingFrame {
  _PendingFrame({required this.commandValue, required this.predicate});

  final int commandValue;
  final bool Function(RingFrame frame) predicate;
  final Completer<Result<RingFrame, BleFailure>> _completer =
      Completer<Result<RingFrame, BleFailure>>();

  Future<Result<RingFrame, BleFailure>> get future => _completer.future;

  void complete(Result<RingFrame, BleFailure> result) {
    if (!_completer.isCompleted) {
      _completer.complete(result);
    }
  }
}
