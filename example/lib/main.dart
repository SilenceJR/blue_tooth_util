import 'dart:async';

import 'package:blue_tooth_util/blue_tooth_util.dart';
import 'package:common/common.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tostore/tostore.dart';

void main() {
  runApp(const BleDebugApp());
}

class BleDebugApp extends StatelessWidget {
  const BleDebugApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Ring BLE Debug',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        cardTheme: const CardThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      home: const BleDebugPage(),
    );
  }
}

class CachedBleDevice {
  const CachedBleDevice({
    required this.deviceId,
    this.name,
    this.rawName,
    this.rssi,
    this.services = const [],
    this.lastConnectedAt,
    this.deviceInfo,
  });

  final String deviceId;
  final String? name;
  final String? rawName;
  final int? rssi;
  final List<String> services;
  final DateTime? lastConnectedAt;
  final RingDeviceInfo? deviceInfo;

  String get displayName =>
      name?.isNotEmpty == true ? name! : rawName ?? deviceId;

  BleScanDevice toScanDevice() {
    return BleScanDevice(
      deviceId: deviceId,
      name: name,
      rawName: rawName,
      rssi: rssi,
      services: services,
    );
  }

  CachedBleDevice copyWith({
    String? name,
    String? rawName,
    int? rssi,
    List<String>? services,
    DateTime? lastConnectedAt,
    RingDeviceInfo? deviceInfo,
  }) {
    return CachedBleDevice(
      deviceId: deviceId,
      name: name ?? this.name,
      rawName: rawName ?? this.rawName,
      rssi: rssi ?? this.rssi,
      services: services ?? this.services,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      deviceInfo: deviceInfo ?? this.deviceInfo,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'name': name,
      'rawName': rawName,
      'rssi': rssi,
      'services': services,
      'lastConnectedAt': lastConnectedAt?.toIso8601String(),
      'deviceInfo': deviceInfo == null
          ? null
          : {
              'manufacturer': deviceInfo!.manufacturer,
              'model': deviceInfo!.model,
              'firmwareVersion': deviceInfo!.firmwareVersion,
              'hardwareVersion': deviceInfo!.hardwareVersion,
              'serialNumber': deviceInfo!.serialNumber,
              'protocolVersion': deviceInfo!.protocolVersion,
              'color': deviceInfo!.color,
              'size': deviceInfo!.size,
            },
    };
  }

  factory CachedBleDevice.fromJson(Map<String, dynamic> json) {
    final info = json['deviceInfo'];
    return CachedBleDevice(
      deviceId: json['deviceId']?.toString() ?? '',
      name: json['name']?.toString(),
      rawName: json['rawName']?.toString(),
      rssi: json['rssi'] is num ? (json['rssi'] as num).toInt() : null,
      services:
          (json['services'] as List?)
              ?.map((item) => item.toString())
              .toList() ??
          const [],
      lastConnectedAt: json['lastConnectedAt'] == null
          ? null
          : DateTime.tryParse(json['lastConnectedAt'].toString()),
      deviceInfo: info is Map
          ? RingDeviceInfo(
              manufacturer: info['manufacturer']?.toString() ?? '',
              model: info['model']?.toString() ?? '',
              firmwareVersion: info['firmwareVersion'] is num
                  ? (info['firmwareVersion'] as num).toInt()
                  : 0,
              hardwareVersion: info['hardwareVersion']?.toString() ?? '',
              serialNumber: info['serialNumber']?.toString() ?? '',
              protocolVersion: info['protocolVersion']?.toString() ?? '',
              color: info['color'] is num ? (info['color'] as num).toInt() : 0,
              size: info['size'] is num ? (info['size'] as num).toInt() : 0,
            )
          : null,
    );
  }
}

abstract class BleDebugCache {
  Future<void> init();

  Future<CachedBleDevice?> loadLastDevice();

  Future<List<CachedBleDevice>> loadDevices();

  Future<void> saveDevice(CachedBleDevice device);

  Future<void> saveLastDevice(CachedBleDevice device);

  Future<void> removeDevice(String deviceId);

  Future<void> close();
}

class ToStoreBleDebugCache implements BleDebugCache {
  static const _lastDeviceKey = 'bleDebugLastDevice';
  static const _devicesKey = 'bleDebugDevices';

  ToStore? _db;

  @override
  Future<void> init() async {
    if (_db != null) return;
    final directory = await getApplicationDocumentsDirectory();
    _db = await ToStore.open(
      dbPath: directory.path,
      dbName: 'ble_debug_example',
    );
  }

  @override
  Future<CachedBleDevice?> loadLastDevice() async {
    final value = await _db?.kv.getMap(_lastDeviceKey, isGlobal: true);
    if (value == null) return null;
    return CachedBleDevice.fromJson(value);
  }

  @override
  Future<List<CachedBleDevice>> loadDevices() async {
    final value = await _db?.kv.getList<dynamic>(_devicesKey, isGlobal: true);
    if (value == null) return [];
    return value
        .whereType<Map>()
        .map(
          (item) => CachedBleDevice.fromJson(Map<String, dynamic>.from(item)),
        )
        .where((item) => item.deviceId.isNotEmpty)
        .toList();
  }

  @override
  Future<void> saveDevice(CachedBleDevice device) async {
    final devices = await loadDevices();
    final index = devices.indexWhere(
      (item) => item.deviceId == device.deviceId,
    );
    if (index == -1) {
      devices.insert(0, device);
    } else {
      devices[index] = device;
    }
    devices.sort(
      (a, b) => (b.lastConnectedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(
            a.lastConnectedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
          ),
    );
    await _db?.kv.set(
      _devicesKey,
      devices.map((item) => item.toJson()).toList(),
      isGlobal: true,
    );
  }

  @override
  Future<void> saveLastDevice(CachedBleDevice device) async {
    await _db?.kv.set(_lastDeviceKey, device.toJson(), isGlobal: true);
    await saveDevice(device);
  }

  @override
  Future<void> removeDevice(String deviceId) async {
    final devices = await loadDevices();
    devices.removeWhere((item) => item.deviceId == deviceId);
    await _db?.kv.set(
      _devicesKey,
      devices.map((item) => item.toJson()).toList(),
      isGlobal: true,
    );
    final last = await loadLastDevice();
    if (last?.deviceId == deviceId) {
      await _db?.kv.remove(_lastDeviceKey, isGlobal: true);
    }
  }

  @override
  Future<void> close() async {
    await _db?.close();
  }
}

class BleBackgroundPolicy {
  const BleBackgroundPolicy({
    required this.platformName,
    required this.canSystemMaintainConnection,
    required this.canInteractInBackground,
    required this.reason,
    required this.examplePolicy,
  });

  final String platformName;
  final bool canSystemMaintainConnection;
  final bool canInteractInBackground;
  final String reason;
  final String examplePolicy;
}

class BleDebugController extends GetxController with WidgetsBindingObserver {
  BleDebugController({BlueToothSdk? sdk, BleDebugCache? cache})
    : sdk = sdk ?? BlueToothSdk(),
      _cache = cache ?? ToStoreBleDebugCache();

  final BlueToothSdk sdk;
  final BleDebugCache _cache;
  final availability = BleAvailability.unknown.obs;
  final devices = <BleScanDevice>[].obs;
  final savedDevices = <CachedBleDevice>[].obs;
  final lastDevice = Rxn<CachedBleDevice>();
  final autoReconnect = true.obs;
  final appLifecycle = AppLifecycleState.resumed.obs;
  final backgroundPolicy = _resolveBackgroundPolicy().obs;
  final backgroundDisconnected = false.obs;
  final logs = <RingFrameLog>[].obs;
  final message = ''.obs;
  final scanning = false.obs;
  final connecting = false.obs;
  final connected = false.obs;
  final flipping = false.obs;
  final finding = false.obs;
  final realtimeSportEnabled = false.obs;
  final selectedScreenOffSeconds = 20.obs;
  final session = Rxn<RingBleSession>();
  final deviceInfo = Rxn<RingDeviceInfo>();
  final battery = Rxn<RingBattery>();
  final ringTime = Rxn<DateTime>();
  final sport = Rxn<RingRealtimeSport>();
  final buttonCount = Rxn<RingButtonCount>();
  final zikrDay = Rxn<RingZikrDay>();
  final screenOffTime = Rxn<RingScreenOffTime>();
  final screenDirection = Rxn<RingScreenDirection>();
  final prayerReminders = <RingPrayerReminder>[].obs;
  final actionState = Rxn<RingActionState>();

  final _subscriptions = <StreamSubscription>[];
  final _sessionSubscriptions = <StreamSubscription>[];
  bool _cacheReady = false;
  bool _manualDisconnected = false;
  bool _backgroundDisconnected = false;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _subscriptions.add(
      sdk.availabilityStream.listen((state) => availability.value = state),
    );
    _subscriptions.add(
      sdk.scanStream.listen((device) {
        final index = devices.indexWhere(
          (item) => item.deviceId == device.deviceId,
        );
        if (index == -1) {
          devices.add(device);
        } else {
          devices[index] = device;
        }
      }),
    );
    refreshAvailability();
    _restoreCacheAndReconnect();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appLifecycle.value = state;
    if (state == AppLifecycleState.resumed) {
      _handleForeground();
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _handleBackground();
    }
  }

  Future<void> _restoreCacheAndReconnect() async {
    try {
      await _cache.init();
      _cacheReady = true;
      savedDevices.assignAll(await _cache.loadDevices());
      lastDevice.value = await _cache.loadLastDevice();
      final last = lastDevice.value;
      if (last != null && autoReconnect.value) {
        message.value = 'Restored ${last.displayName}, reconnecting...';
        await connectCached(last, automatic: true);
      }
    } catch (error) {
      message.value = 'Cache init failed: $error';
    }
  }

  Future<void> _handleBackground() async {
    final current = session.value;
    if (current == null) return;
    _backgroundDisconnected = true;
    backgroundDisconnected.value = true;
    message.value = 'App moved to background, disconnecting BLE link';
    await _disconnectCurrent(disposeOnly: false);
  }

  Future<void> _handleForeground() async {
    if (!autoReconnect.value || _manualDisconnected) return;
    final last = lastDevice.value;
    if (last == null || connected.value || connecting.value) return;
    final suffix = _backgroundDisconnected ? ' after background' : '';
    _backgroundDisconnected = false;
    message.value = 'App resumed$suffix, reconnecting ${last.displayName}';
    await connectCached(last, automatic: true);
  }

  Future<void> requestPermissions() async {
    _show(await sdk.requestPermissions(), 'Bluetooth permissions ready');
  }

  Future<void> refreshAvailability() async {
    final result = await sdk.getAvailability();
    result.match(
      ok: (value) => availability.value = value,
      err: (err) => message.value = err.message,
    );
  }

  Future<void> startScan({bool unfiltered = false}) async {
    devices.clear();
    scanning.value = true;
    final result = await sdk.startScan(unfiltered: unfiltered);
    _show(result, unfiltered ? 'Unfiltered scan started' : 'Ring scan started');
    if (result.isErr) scanning.value = false;
  }

  Future<void> stopScan() async {
    final result = await sdk.stopScan();
    scanning.value = false;
    _show(result, 'Scan stopped');
  }

  Future<void> connect(BleScanDevice device) async {
    _manualDisconnected = false;
    connecting.value = true;
    final result = await sdk.connect(device);
    connecting.value = false;
    result.match(
      ok: (value) async {
        final ringSession = value as RingBleSession;
        final cached = CachedBleDevice(
          deviceId: device.deviceId,
          name: device.name,
          rawName: device.rawName,
          rssi: device.rssi,
          services: device.services,
          lastConnectedAt: DateTime.now(),
        );
        session.value = ringSession;
        connected.value = true;
        _bindSession(ringSession);
        await _saveConnectedDevice(cached);
        unawaited(queryDeviceInfo());
        message.value = 'Connected ${device.name ?? device.deviceId}';
      },
      err: (err) => message.value = err.message,
    );
  }

  Future<void> connectCached(
    CachedBleDevice device, {
    bool automatic = false,
  }) async {
    if (!automatic) _manualDisconnected = false;
    await connect(device.toScanDevice());
  }

  Future<void> disconnect() async {
    _manualDisconnected = true;
    final result = await _disconnectCurrent(disposeOnly: false);
    _show(result, 'Disconnected');
  }

  Future<Result<void, dynamic>> _disconnectCurrent({
    required bool disposeOnly,
  }) async {
    final current = session.value;
    if (current == null) return const Result.ok(null);
    final result = disposeOnly
        ? const Result.ok(null)
        : await current.disconnect();
    await _clearSession(current);
    return result;
  }

  Future<void> _clearSession(RingBleSession current) async {
    for (final subscription in _sessionSubscriptions) {
      await subscription.cancel();
    }
    _sessionSubscriptions.clear();
    await current.dispose();
    session.value = null;
    connected.value = false;
    flipping.value = false;
    finding.value = false;
    realtimeSportEnabled.value = false;
    actionState.value = null;
    screenDirection.value = null;
    prayerReminders.clear();
  }

  Future<void> queryDeviceInfo() async {
    final current = session.value;
    if (current == null) return;
    final result = await current.queryDeviceInfo();
    result.map((value) async {
      deviceInfo.value = value;
      await _saveDeviceInfo(value);
    });
    // if (result case Success<RingDeviceInfo>(:final value)) {
    //   deviceInfo.value = value;
    //   await _saveDeviceInfo(value);
    // }
    _show(result, 'Device info loaded');
  }

  Future<void> queryBattery() async {
    final current = session.value;
    if (current == null) return;
    final result = await current.queryBattery();
    result.map((value) {
      battery.value = value;
    });
    _show(result, 'Battery loaded');
  }

  Future<void> queryButtonCount() async {
    final current = session.value;
    if (current == null) return;
    final result = await current.queryButtonCount();
    result.map((value) {
      buttonCount.value = value;
    });
    _show(result, 'Button count loaded');
  }

  Future<void> syncTime() async {
    final result = await session.value?.setTime(DateTime.now());
    _show(result, 'Time synced');
  }

  Future<void> queryTime() async {
    final result = await session.value?.queryTime();
    result?.map((value) => ringTime.value = value);
    _show(result, 'Time loaded');
  }

  Future<void> toggleRealtimeSport() async {
    final enabled = !realtimeSportEnabled.value;
    final result = await session.value?.setRealtimeSportEnabled(enabled);
    if (result?.isOk ?? false) realtimeSportEnabled.value = enabled;
    _show(
      result,
      enabled ? 'Realtime sport enabled' : 'Realtime sport disabled',
    );
  }

  Future<void> flipScreen() async {
    final current = session.value;
    if (current == null || flipping.value) return;
    flipping.value = true;
    final result = await current.flipScreen();
    result.map((value) {
      screenDirection.value = value;
    });
    flipping.value = false;
    _show(result, 'Screen flip done');
  }

  Future<void> queryScreenDirection() async {
    final current = session.value;
    if (current == null) return;
    final result = await current.queryScreenDirection();
    result.map((value) {
      screenDirection.value = value;
    });
    _show(result, 'Screen direction loaded');
  }

  Future<void> startFindRing() async {
    final current = session.value;
    if (current == null || finding.value) return;
    finding.value = true;
    final result = await current.startFindRing();
    finding.value = false;
    _show(result, 'Find ring done');
  }

  Future<void> stopFindRing() async {
    final result = await session.value?.stopFindRing();
    _show(result, 'Find ring stopped');
  }

  Future<void> setScreenOffTime() async {
    final result = await session.value?.setScreenOffTime(
      selectedScreenOffSeconds.value,
    );
    _show(result, 'Screen off time set');
  }

  // Future<void> queryPrayerReminders() async {
  //   final current = session.value;
  //   if (current == null) return;
  //   final result = await current.queryPrayerReminders();
  //   if (result case Success<List<RingPrayerReminder>>(:final value)) {
  //     prayerReminders.assignAll(value);
  //   }
  //   _show(result, 'Prayer reminders loaded');
  // }

  // Future<void> writeSamplePrayerReminder() async {
  //   final current = session.value;
  //   if (current == null) return;
  //   final sample = [
  //     const RingPrayerReminder(
  //       enabled: true,
  //       hour: 8,
  //       minute: 30,
  //       weekdaysMask: 0x7F,
  //     ),
  //   ];
  //   final result = await current.setPrayerReminders(sample);
  //   if (result.isSuccess) {
  //     prayerReminders.assignAll(sample);
  //   }
  //   _show(result, 'Sample prayer reminder written');
  // }

  Future<void> softDisconnect() async {
    _manualDisconnected = true;
    final result = await session.value?.softDisconnect();
    if (result?.isOk ?? false) {
      final current = session.value;
      if (current != null) {
        await _clearSession(current);
      }
    }
    _show(result, 'Soft disconnect accepted');
  }

  Future<void> removeSavedDevice(CachedBleDevice device) async {
    await _cache.removeDevice(device.deviceId);
    savedDevices.assignAll(await _cache.loadDevices());
    lastDevice.value = await _cache.loadLastDevice();
    if (session.value?.deviceId == device.deviceId) {
      await disconnect();
    }
    message.value = 'Removed ${device.displayName}';
  }

  Future<void> switchDevice(CachedBleDevice device) async {
    final current = session.value;
    if (current != null && current.deviceId != device.deviceId) {
      await _disconnectCurrent(disposeOnly: false);
    }
    await connectCached(device);
  }

  Future<void> _saveConnectedDevice(CachedBleDevice device) async {
    if (!_cacheReady) return;
    await _cache.saveLastDevice(device);
    lastDevice.value = device;
    savedDevices.assignAll(await _cache.loadDevices());
  }

  Future<void> _saveDeviceInfo(RingDeviceInfo info) async {
    if (!_cacheReady) return;
    final base =
        lastDevice.value ??
        (session.value == null
            ? null
            : CachedBleDevice(deviceId: session.value!.deviceId));
    if (base == null) return;
    final updated = base.copyWith(
      lastConnectedAt: DateTime.now(),
      deviceInfo: info,
    );
    await _cache.saveLastDevice(updated);
    lastDevice.value = updated;
    savedDevices.assignAll(await _cache.loadDevices());
  }

  void clearLogs() {
    logs.clear();
  }

  void _bindSession(RingBleSession current) {
    for (final subscription in _sessionSubscriptions) {
      subscription.cancel();
    }
    _sessionSubscriptions.clear();
    _sessionSubscriptions.add(current.logs.listen(logs.add));
    _sessionSubscriptions.add(
      current.errors.listen((failure) => message.value = failure.message),
    );
    _sessionSubscriptions.add(
      current.batteryStream.listen((value) => battery.value = value),
    );
    _sessionSubscriptions.add(
      current.deviceInfoStream.listen((value) {
        deviceInfo.value = value;
        _saveDeviceInfo(value);
      }),
    );
    _sessionSubscriptions.add(
      current.timeStream.listen((value) => ringTime.value = value),
    );
    _sessionSubscriptions.add(
      current.sportStream.listen((value) => sport.value = value),
    );
    _sessionSubscriptions.add(
      current.buttonCountStream.listen((value) => buttonCount.value = value),
    );
    _sessionSubscriptions.add(
      current.zikrDayStream.listen((value) => zikrDay.value = value),
    );
    _sessionSubscriptions.add(
      current.screenOffTimeStream.listen((value) {
        screenOffTime.value = value;
        selectedScreenOffSeconds.value = value.seconds;
      }),
    );
    _sessionSubscriptions.add(
      current.screenDirectionStream.listen((value) {
        screenDirection.value = value;
      }),
    );
    _sessionSubscriptions.add(
      current.prayerRemindersStream.listen((value) {
        prayerReminders.assignAll(value);
      }),
    );
    _sessionSubscriptions.add(
      current.actionStateStream.listen(_handleActionState),
    );
    _sessionSubscriptions.add(
      current.connectionStream.listen((value) {
        connected.value = value;
        if (!value && session.value == current) {
          session.value = null;
        }
      }),
    );
  }

  void _handleActionState(RingActionState state) {
    actionState.value = state;
    final busy =
        state.phase == RingActionPhase.sending ||
        state.phase == RingActionPhase.accepted;
    if (state.command == RingCommand.screenFlip) {
      flipping.value = busy;
    } else if (state.command == RingCommand.findRing) {
      finding.value = busy;
    }
    if (state.phase == RingActionPhase.done ||
        state.phase == RingActionPhase.failed) {
      message.value = _actionStateText(state);
    }
  }

  String _actionStateText(RingActionState state) {
    final status = state.status == null
        ? ''
        : ' status 0x${state.status!.toRadixString(16).padLeft(2, '0')}';
    final detail = state.failure?.message ?? state.message;
    final direction = state.screenDirection == null
        ? ''
        : ' ${state.screenDirection!.label}';
    return '${state.command.label} ${state.phase.name}$status'
        '$direction${detail == null ? '' : ': $detail'}';
  }

  void _show<T>(Result<T, dynamic>? result, String successMessage) {
    if (result == null) return;
    result.match(
      ok: (value) => message.value = successMessage,
      err: (err) => message.value = err.message,
    );
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    for (final subscription in _sessionSubscriptions) {
      subscription.cancel();
    }
    session.value?.dispose();
    _cache.close();
    sdk.dispose();
    super.onClose();
  }
}

BleBackgroundPolicy _resolveBackgroundPolicy() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      return const BleBackgroundPolicy(
        platformName: 'iOS',
        canSystemMaintainConnection: true,
        canInteractInBackground: false,
        reason:
            'iOS may keep CoreBluetooth links only with Bluetooth background mode and system permission; ordinary debug UI cannot reliably run foreground-style operations after background.',
        examplePolicy:
            'This example disconnects on background and reconnects the cached last device on resume.',
      );
    case TargetPlatform.android:
      return const BleBackgroundPolicy(
        platformName: 'Android',
        canSystemMaintainConnection: true,
        canInteractInBackground: false,
        reason:
            'Android may keep a GATT link while the process lives, but reliable background interaction needs a foreground service and granted Bluetooth permissions.',
        examplePolicy:
            'This example disconnects on background to avoid occupying the ring, then reconnects on resume.',
      );
    default:
      return BleBackgroundPolicy(
        platformName: defaultTargetPlatform.name,
        canSystemMaintainConnection: false,
        canInteractInBackground: false,
        reason:
            'Background BLE behavior is platform-specific and not guaranteed.',
        examplePolicy:
            'This example treats background as unavailable and reconnects on resume.',
      );
  }
}

class BleDebugPage extends StatelessWidget {
  const BleDebugPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = Get.isRegistered<BleDebugController>()
        ? Get.find<BleDebugController>()
        : Get.put(BleDebugController());
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ring BLE Debug'),
        actions: [
          IconButton(
            tooltip: 'Refresh Bluetooth state',
            onPressed: controller.refreshAvailability,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusPanel(controller: controller),
            const SizedBox(height: 12),
            _SavedDevicesPanel(controller: controller),
            const SizedBox(height: 12),
            _ScanPanel(controller: controller),
            const SizedBox(height: 12),
            _DevicePanel(controller: controller),
            const SizedBox(height: 12),
            _CommandPanel(controller: controller),
            const SizedBox(height: 12),
            _LogPanel(controller: controller),
          ],
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.controller});

  final BleDebugController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final policy = controller.backgroundPolicy.value;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Bluetooth', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  Chip(label: Text(controller.availability.value.name)),
                  Chip(
                    label: Text(
                      controller.connected.value ? 'connected' : 'disconnected',
                    ),
                  ),
                  Chip(label: Text(controller.appLifecycle.value.name)),
                  Chip(label: Text(policy.platformName)),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto reconnect last device'),
                subtitle: Text(
                  controller.backgroundDisconnected.value
                      ? 'Last background transition disconnected BLE'
                      : 'Resume will reconnect cached last device',
                ),
                value: controller.autoReconnect.value,
                onChanged: (value) => controller.autoReconnect.value = value,
              ),
              _kv(
                'Background',
                policy.canSystemMaintainConnection
                    ? 'system may keep link'
                    : 'not guaranteed',
              ),
              _kv(
                'Interaction',
                policy.canInteractInBackground
                    ? 'background interaction available'
                    : 'foreground/debug interaction only',
              ),
              Text(policy.reason, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(
                policy.examplePolicy,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (controller.message.value.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(controller.message.value),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: controller.requestPermissions,
                icon: const Icon(Icons.bluetooth),
                label: const Text('Request permissions'),
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _SavedDevicesPanel extends StatelessWidget {
  const _SavedDevicesPanel({required this.controller});

  final BleDebugController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cached devices',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (controller.savedDevices.isEmpty)
                const Text('No cached devices yet'),
              for (final device in controller.savedDevices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    controller.lastDevice.value?.deviceId == device.deviceId
                        ? Icons.bookmark
                        : Icons.bluetooth,
                  ),
                  title: Text(device.displayName),
                  subtitle: Text(
                    [
                      device.deviceId,
                      if (device.deviceInfo != null)
                        '${device.deviceInfo!.manufacturer} ${device.deviceInfo!.model}',
                      if (device.lastConnectedAt != null)
                        'last ${device.lastConnectedAt!.toLocal()}',
                    ].join('\n'),
                  ),
                  isThreeLine: device.deviceInfo != null,
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        tooltip: 'Switch to device',
                        onPressed: controller.connecting.value
                            ? null
                            : () => controller.switchDevice(device),
                        icon: const Icon(Icons.swap_horiz),
                      ),
                      IconButton(
                        tooltip: 'Remove cache',
                        onPressed: () => controller.removeSavedDevice(device),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanPanel extends StatelessWidget {
  const _ScanPanel({required this.controller});

  final BleDebugController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Scan', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: controller.scanning.value
                        ? null
                        : () => controller.startScan(),
                    icon: const Icon(Icons.radar),
                    label: const Text('Ring scan'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.scanning.value
                        ? null
                        : () => controller.startScan(unfiltered: true),
                    icon: const Icon(Icons.search),
                    label: const Text('All devices'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.scanning.value
                        ? controller.stopScan
                        : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final device in controller.devices)
                _ScanDeviceTile(controller: controller, device: device),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScanDeviceTile extends StatelessWidget {
  const _ScanDeviceTile({required this.controller, required this.device});

  final BleDebugController controller;
  final BleScanDevice device;

  @override
  Widget build(BuildContext context) {
    final advertisement = device.parseRingAdvertisement().valueOrNull;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.bluetooth_connected),
      title: Text(
        device.name?.isNotEmpty == true ? device.name! : device.deviceId,
      ),
      subtitle: Text(
        [
          'RSSI ${device.rssi ?? '-'}  ${device.deviceId}',
          if (advertisement != null)
            'ADV mac ${advertisement.macAddressText} fw ${advertisement.firmwareVersion} bound ${advertisement.isBound}',
        ].join('\n'),
      ),
      isThreeLine: advertisement != null,
      trailing: FilledButton(
        onPressed: controller.connecting.value
            ? null
            : () => controller.connect(device),
        child: const Text('Connect'),
      ),
    );
  }
}

class _DevicePanel extends StatelessWidget {
  const _DevicePanel({required this.controller});

  final BleDebugController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final info = controller.deviceInfo.value;
      final battery = controller.battery.value;
      final sport = controller.sport.value;
      final zikr = controller.zikrDay.value;
      final reminders = controller.prayerReminders;
      final advertisement = controller.session.value?.advertisement;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ring state',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _kv(
                'Device',
                info == null ? '-' : '${info.manufacturer} ${info.model}',
              ),
              _kv('Firmware', info?.firmwareVersion.toString() ?? '-'),
              _kv('Protocol', info?.protocolVersion ?? '-'),
              _kv('ADV MAC', advertisement?.macAddressText ?? '-'),
              _kv(
                'ADV Firmware',
                advertisement?.firmwareVersion.toString() ?? '-',
              ),
              _kv(
                'Bound',
                advertisement == null ? '-' : advertisement.isBound.toString(),
              ),
              _kv(
                'Battery',
                battery == null
                    ? '-'
                    : '${battery.percent}% ${battery.chargingState.name}',
              ),
              _kv(
                'Ring time',
                controller.ringTime.value?.toLocal().toString() ?? '-',
              ),
              _kv(
                'Button count',
                controller.buttonCount.value?.count.toString() ?? '-',
              ),
              _kv('Steps', sport?.steps.toString() ?? '-'),
              _kv(
                'Screen off',
                controller.screenOffTime.value?.seconds.toString() ?? '-',
              ),
              _kv('Direction', controller.screenDirection.value?.label ?? '-'),
              // _kv(
              //   'Reminders',
              //   reminders.isEmpty
              //       ? '-'
              //       : reminders
              //             .map(
              //               (item) =>
              //                   '${item.enabled ? 'on' : 'off'} ${item.timeText} ${item.everyDay ? 'daily' : 'mask ${item.weekdaysMask}'}',
              //             )
              //             .join('\n'),
              // ),
              _kv(
                'Zikr day',
                zikr == null
                    ? '-'
                    : '${zikr.date.toIso8601String().split('T').first} total ${zikr.hourlyCounts.fold<int>(0, (a, b) => a + b)}',
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _CommandPanel extends StatelessWidget {
  const _CommandPanel({required this.controller});

  final BleDebugController controller;

  bool get enabled =>
      controller.connected.value && controller.session.value != null;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Commands', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _button(
                    Icons.info,
                    'Info',
                    enabled,
                    controller.queryDeviceInfo,
                  ),
                  _button(
                    Icons.battery_4_bar,
                    'Battery',
                    enabled,
                    controller.queryBattery,
                  ),
                  _button(
                    Icons.pin,
                    'Count',
                    enabled,
                    controller.queryButtonCount,
                  ),
                  _button(
                    Icons.sync,
                    'Sync time',
                    enabled,
                    controller.syncTime,
                  ),
                  _button(
                    Icons.schedule,
                    'Query time',
                    enabled,
                    controller.queryTime,
                  ),
                  _button(
                    Icons.directions_walk,
                    controller.realtimeSportEnabled.value
                        ? 'Sport off'
                        : 'Sport on',
                    enabled,
                    controller.toggleRealtimeSport,
                  ),
                  _button(
                    Icons.screen_rotation,
                    controller.flipping.value ? 'Flipping' : 'Flip',
                    enabled && !controller.flipping.value,
                    controller.flipScreen,
                  ),
                  _button(
                    Icons.screen_rotation_alt,
                    'Direction',
                    enabled,
                    controller.queryScreenDirection,
                  ),
                  _button(
                    Icons.vibration,
                    controller.finding.value ? 'Finding' : 'Find',
                    enabled && !controller.finding.value,
                    controller.startFindRing,
                  ),
                  _button(
                    Icons.stop_circle,
                    'Stop find',
                    enabled,
                    controller.stopFindRing,
                  ),
                  _button(
                    Icons.link_off,
                    'Soft disconnect',
                    enabled,
                    controller.softDisconnect,
                  ),
                  // _button(
                  //   Icons.alarm,
                  //   'Read reminders',
                  //   enabled,
                  //   controller.queryPrayerReminders,
                  // ),
                  // _button(
                  //   Icons.alarm_add,
                  //   'Write sample',
                  //   enabled,
                  //   controller.writeSamplePrayerReminder,
                  // ),
                  _button(
                    Icons.bluetooth_disabled,
                    'Disconnect',
                    enabled,
                    controller.disconnect,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Screen off'),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: controller.selectedScreenOffSeconds.value,
                    items: const [10, 20, 30, 40, 50, 60]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('${value}s'),
                          ),
                        )
                        .toList(),
                    onChanged: enabled
                        ? (value) {
                            if (value != null) {
                              controller.selectedScreenOffSeconds.value = value;
                            }
                          }
                        : null,
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: enabled ? controller.setScreenOffTime : null,
                    icon: const Icon(Icons.timer),
                    label: const Text('Set'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _ActionStateLine(controller: controller),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button(
    IconData icon,
    String label,
    bool enabled,
    Future<void> Function() action,
  ) {
    return OutlinedButton.icon(
      onPressed: enabled ? action : null,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _ActionStateLine extends StatelessWidget {
  const _ActionStateLine({required this.controller});

  final BleDebugController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.actionState.value;
    final text = state == null ? '-' : controller._actionStateText(state);
    final color = switch (state?.phase) {
      RingActionPhase.failed => Theme.of(context).colorScheme.error,
      RingActionPhase.done => Theme.of(context).colorScheme.primary,
      RingActionPhase.sending ||
      RingActionPhase.accepted => Theme.of(context).colorScheme.tertiary,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: 92, child: Text('Action')),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.controller});

  final BleDebugController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final logs = controller.logs.reversed.take(80).toList();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Frame log',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Clear logs',
                    onPressed: controller.clearLogs,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final log in logs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${log.direction} ${log.title} ${log.hex}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

Widget _kv(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 100, child: Text(label)),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
