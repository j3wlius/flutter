import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const RDFitBridgeApp());
}

class RDFitBridgeApp extends StatelessWidget {
  const RDFitBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RDFit Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00D4AA),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0A0E14),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0E14),
          elevation: 0,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<ScanResult> scanResults = [];
  bool isScanning = false;
  bool isConnecting = false;
  bool isSyncing = false;
  BluetoothDevice? connectedDevice;
  String statusMessage = 'Tap scan to find your RDFit watch';

  // Health data from watch
  int? lastSteps;
  int? lastHeartRate;
  int? lastCalories;
  int? lastDistance;

  // Health Connect
  final Health health = Health();
  bool healthConnectAvailable = false;
  bool healthConnectAuthorized = false;
  String healthConnectStatus = 'Checking...';

  @override
  void initState() {
    super.initState();
    _checkHealthConnect();
  }

  Future<void> _checkHealthConnect() async {
    try {
      // Check if Health Connect is installed
      final status = await health.getHealthConnectSdkStatus();

      if (status == HealthConnectSdkStatus.sdkAvailable) {
        healthConnectAvailable = true;
        healthConnectStatus = 'Available - tap to authorize';
        await _initHealthConnect();
      } else if (status ==
          HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired) {
        healthConnectAvailable = false;
        healthConnectStatus = 'Update required';
      } else {
        healthConnectAvailable = false;
        healthConnectStatus = 'Not installed - tap to install';
      }
      setState(() {});
    } catch (e) {
      print('Health Connect check error: $e');
      healthConnectAvailable = false;
      healthConnectStatus = 'Not available on this device';
      setState(() {});
    }
  }

  Future<void> _installHealthConnect() async {
    try {
      await health.installHealthConnect();
      // After installation, recheck
      await Future.delayed(const Duration(seconds: 2));
      await _checkHealthConnect();
    } catch (e) {
      print('Failed to install Health Connect: $e');
      setState(() => healthConnectStatus = 'Installation failed');
    }
  }

  Future<void> _initHealthConnect() async {
    try {
      await health.configure();

      final types = [
        HealthDataType.STEPS,
        HealthDataType.HEART_RATE,
        HealthDataType.ACTIVE_ENERGY_BURNED,
        HealthDataType.DISTANCE_DELTA,
      ];

      final permissions = types
          .map((e) => HealthDataAccess.READ_WRITE)
          .toList();

      healthConnectAuthorized = await health.requestAuthorization(
        types,
        permissions: permissions,
      );

      if (healthConnectAuthorized) {
        healthConnectStatus = 'Connected & authorized';
        print('✅ Health Connect authorized');
      } else {
        healthConnectStatus = 'Available - needs permission';
        print('⚠️ Health Connect not authorized');
      }
      setState(() {});
    } catch (e) {
      print('Health Connect init error: $e');
      healthConnectStatus = 'Error: ${e.toString().split(':').last.trim()}';
      setState(() {});
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
  }

  Future<void> startScan() async {
    await _requestPermissions();

    if (await FlutterBluePlus.isSupported == false) {
      setState(() => statusMessage = 'Bluetooth not supported');
      return;
    }

    await FlutterBluePlus.turnOn();

    setState(() {
      scanResults.clear();
      isScanning = true;
      statusMessage = 'Scanning for RDFit watch...';
    });

    FlutterBluePlus.scanResults.listen((results) {
      // Filter for RDFit devices or show all if debugging
      final filtered = results.where((r) {
        final name = r.device.platformName.toLowerCase();
        return name.contains('rdfit') ||
            name.contains('h4') ||
            name.contains('watch') ||
            name.contains('band') ||
            name.isNotEmpty; // Show all named devices
      }).toList();

      setState(() => scanResults = filtered);
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

    setState(() {
      isScanning = false;
      statusMessage = scanResults.isEmpty
          ? 'No devices found. Make sure watch is awake.'
          : 'Found ${scanResults.length} device(s)';
    });
  }

  Future<void> connectAndSync(BluetoothDevice device) async {
    setState(() {
      isConnecting = true;
      statusMessage = 'Connecting to ${device.platformName}...';
    });

    try {
      // Connect with timeout and retry
      await device.connect(
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      setState(() {
        connectedDevice = device;
        statusMessage = 'Connected! Discovering services...';
      });

      await Future.delayed(const Duration(milliseconds: 500));

      await _syncWatchData(device);
    } on FlutterBluePlusException catch (e) {
      setState(() {
        statusMessage = 'Connection failed: ${e.description}';
        isConnecting = false;
      });

      // Retry once
      if (e.code == 133) {
        setState(() => statusMessage = 'Retrying connection...');
        await Future.delayed(const Duration(seconds: 2));
        try {
          await device.connect(timeout: const Duration(seconds: 15));
          await _syncWatchData(device);
        } catch (e2) {
          setState(() {
            statusMessage = 'Connection failed after retry';
            isConnecting = false;
          });
        }
      }
    } catch (e) {
      setState(() {
        statusMessage = 'Error: $e';
        isConnecting = false;
      });
    }
  }

  Future<void> _syncWatchData(BluetoothDevice device) async {
    setState(() {
      isSyncing = true;
      statusMessage = 'Syncing health data...';
    });

    try {
      List<BluetoothService> services = await device.discoverServices();

      // Collect ALL writable and notify characteristics
      List<BluetoothCharacteristic> writableChars = [];
      List<BluetoothCharacteristic> notifyChars = [];

      for (var service in services) {
        print('Service: ${service.uuid}');
        for (var char in service.characteristics) {
          print('  Char: ${char.uuid} - props: ${char.properties}');

          // Collect all writable chars
          if (char.properties.write || char.properties.writeWithoutResponse) {
            writableChars.add(char);
          }
          // Collect all notify chars
          if (char.properties.notify || char.properties.indicate) {
            notifyChars.add(char);
          }
        }
      }

      print(
        '📊 Found ${writableChars.length} writable, ${notifyChars.length} notify chars',
      );

      // Enable notifications on ALL notify characteristics
      final dataBuffer = <int>[];
      List<StreamSubscription> subscriptions = [];

      for (var notifyChar in notifyChars) {
        try {
          await notifyChar.setNotifyValue(true);
          print('🔔 Enabled notify on ${notifyChar.uuid}');

          var sub = notifyChar.lastValueStream.listen((data) {
            if (data.isNotEmpty) {
              print('📥 [${notifyChar.uuid}] Received: ${_bytesToHex(data)}');
              dataBuffer.addAll(data);
              _parseHealthData(data);
            }
          });
          subscriptions.add(sub);
        } catch (e) {
          print('Failed to enable notify on ${notifyChar.uuid}: $e');
        }
      }

      setState(() => statusMessage = 'Sending commands...');
      await Future.delayed(const Duration(milliseconds: 500));

      // Find ae01 (write) characteristic specifically
      BluetoothCharacteristic? ae01Char;
      for (var char in writableChars) {
        if (char.uuid.toString().toLowerCase().contains('ae01')) {
          ae01Char = char;
          break;
        }
      }

      if (ae01Char == null) {
        print('❌ Could not find ae01 characteristic');
        setState(() => statusMessage = 'Protocol error: ae01 not found');
        return;
      }

      print('🎯 Using ae01 for commands');

      // Commands from Wireshark - ORDER MATTERS: Sync first, then Login
      // Sync command (Frame 724 - triggers data request)
      List<int> syncCmd = [
        0xed,
        0x40,
        0x00,
        0xd3,
        0x00,
        0x03,
        0x01,
        0x03,
        0x01,
      ];

      // Login command (Frame 725 - authentication)
      List<int> loginCmd = [
        0xfe,
        0xdc,
        0xba,
        0xc0,
        0x03,
        0x00,
        0x06,
        0x6c,
        0xff,
        0xff,
        0xff,
        0xff,
        0x00,
        0xef,
      ];

      // Step 1: Send SYNC command first
      try {
        await ae01Char.write(syncCmd, withoutResponse: true);
        print('✅ Step 1: Sync command sent');
      } catch (e) {
        print('❌ Sync failed: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));

      // Step 2: Send LOGIN command
      try {
        await ae01Char.write(loginCmd, withoutResponse: true);
        print('✅ Step 2: Login command sent');
      } catch (e) {
        print('❌ Login failed: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));

      // Step 3: Request today's steps (common command pattern)
      List<int> getStepsCmd = [0xed, 0x52, 0x00, 0x00, 0x00, 0x00];
      try {
        await ae01Char.write(getStepsCmd, withoutResponse: true);
        print('✅ Step 3: Get steps command sent');
      } catch (e) {
        print('❌ Get steps failed: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));

      // Step 4: Request heart rate
      List<int> getHRCmd = [0xed, 0x53, 0x00, 0x00, 0x00, 0x00];
      try {
        await ae01Char.write(getHRCmd, withoutResponse: true);
        print('✅ Step 4: Get heart rate command sent');
      } catch (e) {
        print('❌ Get HR failed: $e');
      }

      setState(() => statusMessage = 'Waiting for watch response...');

      // Wait for responses
      await Future.delayed(const Duration(seconds: 10));

      // Cleanup subscriptions
      for (var sub in subscriptions) {
        sub.cancel();
      }

      print('📦 Total received: ${dataBuffer.length} bytes');
      if (dataBuffer.isNotEmpty) {
        print('📦 Buffer: ${_bytesToHex(dataBuffer)}');
      }

      // Show results
      if (lastSteps != null || lastHeartRate != null) {
        String result = 'Sync complete!';
        if (lastSteps != null) result += ' Steps: $lastSteps';
        if (lastHeartRate != null) result += ' HR: $lastHeartRate';
        await _writeToHealthConnect();
        setState(() => statusMessage = result);
      } else if (dataBuffer.isNotEmpty) {
        setState(() => statusMessage = 'Connected. Tap sync again for data.');
      } else {
        setState(() => statusMessage = 'No response. Pair in RDFit app first.');
      }
    } catch (e) {
      setState(() => statusMessage = 'Sync error: $e');
    } finally {
      setState(() {
        isSyncing = false;
        isConnecting = false;
      });
    }
  }

  void _parseHealthData(List<int> data) {
    if (data.isEmpty) return;

    print('🔍 Parsing ${data.length} bytes: ${_bytesToHex(data)}');

    int header = data[0];

    // ED header packets (commands/responses)
    if (header == 0xED && data.length >= 4) {
      int cmdType = data[1];

      // ED 60 = Device info (contains device name as ASCII)
      if (cmdType == 0x60) {
        String deviceName = '';
        for (int i = 9; i < data.length && data[i] != 0; i++) {
          if (data[i] >= 32 && data[i] < 127) {
            deviceName += String.fromCharCode(data[i]);
          }
        }
        if (deviceName.isNotEmpty) {
          print('📱 Device: $deviceName');
        }
      }

      // ED 51 = Steps data response
      if (cmdType == 0x51 && data.length >= 8) {
        int steps = data[4] | (data[5] << 8);
        if (steps > 0 && steps < 100000) {
          setState(() => lastSteps = steps);
          print('📊 Steps: $steps');
        }
      }

      // ED 53 = Heart rate response
      if (cmdType == 0x53 && data.length >= 6) {
        int hr = data[4];
        if (hr > 30 && hr < 220) {
          setState(() => lastHeartRate = hr);
          print('💓 Heart Rate: $hr bpm');
        }
      }
    }

    // FE DC BA header = Config/Auth packets
    if (header == 0xFE &&
        data.length >= 4 &&
        data[1] == 0xDC &&
        data[2] == 0xBA) {
      print('📦 Config/Auth packet received');

      // Extract steps from config packet
      // Based on analysis, steps are around offset 67-73
      if (data.length >= 70 && lastSteps == null) {
        for (int offset in [67, 68, 69, 70, 71, 72, 73]) {
          if (offset + 1 < data.length) {
            int val = data[offset] | (data[offset + 1] << 8);
            if (val >= 100 && val <= 50000) {
              setState(() => lastSteps = val);
              print('📊 Steps: $val (from config packet)');
              break;
            }
          }
        }
      }
    }

    // ASCII data (device name fragments)
    bool isAscii = data.length >= 5;
    for (int i = 0; i < data.length && i < 10; i++) {
      if (!(data[i] >= 32 && data[i] < 127) && data[i] != 0) {
        isAscii = false;
        break;
      }
    }
    if (isAscii && data[0] >= 32) {
      String text = String.fromCharCodes(data.where((c) => c >= 32 && c < 127));
      if (text.length > 5) {
        print('📝 Device info: $text');
      }
    }
  }

  Future<void> _writeToHealthConnect() async {
    if (!healthConnectAvailable) {
      print('Health Connect not available on this device');
      return;
    }

    if (!healthConnectAuthorized) {
      await _initHealthConnect();
      if (!healthConnectAuthorized) {
        print('Health Connect not authorized');
        return;
      }
    }

    final now = DateTime.now();
    final earlier = now.subtract(const Duration(hours: 1));

    try {
      if (lastSteps != null) {
        await health.writeHealthData(
          value: lastSteps!.toDouble(),
          type: HealthDataType.STEPS,
          startTime: earlier,
          endTime: now,
        );
        print('✅ Wrote $lastSteps steps to Health Connect');
      }

      if (lastHeartRate != null) {
        await health.writeHealthData(
          value: lastHeartRate!.toDouble(),
          type: HealthDataType.HEART_RATE,
          startTime: now.subtract(const Duration(minutes: 1)),
          endTime: now,
        );
        print('✅ Wrote $lastHeartRate bpm to Health Connect');
      }

      if (lastCalories != null) {
        await health.writeHealthData(
          value: lastCalories!.toDouble(),
          type: HealthDataType.ACTIVE_ENERGY_BURNED,
          startTime: earlier,
          endTime: now,
        );
        print('✅ Wrote $lastCalories calories to Health Connect');
      }

      if (lastDistance != null) {
        await health.writeHealthData(
          value: lastDistance!.toDouble(),
          type: HealthDataType.DISTANCE_DELTA,
          startTime: earlier,
          endTime: now,
        );
        print('✅ Wrote $lastDistance m to Health Connect');
      }
    } catch (e) {
      print('Health Connect write error: $e');
    }
  }

  String _bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  Future<void> disconnect() async {
    if (connectedDevice != null) {
      await connectedDevice!.disconnect();
      setState(() {
        connectedDevice = null;
        statusMessage = 'Disconnected';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00D4AA), Color(0xFF00A080)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.watch, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            const Text(
              'RDFit Bridge',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          if (connectedDevice != null)
            IconButton(
              icon: const Icon(Icons.bluetooth_disabled),
              onPressed: disconnect,
              tooltip: 'Disconnect',
            ),
        ],
      ),
      body: Column(
        children: [
          // Status Card
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF1A1F2E),
                  const Color(0xFF1A1F2E).withOpacity(0.8),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF00D4AA).withOpacity(0.3),
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      connectedDevice != null
                          ? Icons.bluetooth_connected
                          : isScanning
                          ? Icons.bluetooth_searching
                          : Icons.bluetooth,
                      color: connectedDevice != null
                          ? const Color(0xFF00D4AA)
                          : Colors.grey,
                      size: 28,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            connectedDevice?.platformName ?? 'No device',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            statusMessage,
                            style: TextStyle(
                              color: Colors.grey[400],
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (isScanning || isConnecting || isSyncing)
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00D4AA),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                if (healthConnectAuthorized)
                  Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: Color(0xFF00D4AA),
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Health Connect: Connected',
                        style: TextStyle(color: Colors.grey[400], fontSize: 12),
                      ),
                    ],
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () {
                      if (!healthConnectAvailable) {
                        _installHealthConnect();
                      } else {
                        _initHealthConnect();
                      }
                    },
                    icon: Icon(
                      healthConnectAvailable ? Icons.lock_open : Icons.download,
                      size: 18,
                    ),
                    label: Text(
                      healthConnectAvailable
                          ? 'Grant Health Connect Permission'
                          : 'Install Health Connect',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: const BorderSide(color: Colors.orange),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Health Data Cards
          if (lastSteps != null || lastHeartRate != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  if (lastSteps != null)
                    Expanded(
                      child: _buildStatCard(
                        'Steps',
                        lastSteps.toString(),
                        Icons.directions_walk,
                        const Color(0xFF4CAF50),
                      ),
                    ),
                  if (lastSteps != null && lastHeartRate != null)
                    const SizedBox(width: 12),
                  if (lastHeartRate != null)
                    Expanded(
                      child: _buildStatCard(
                        'Heart Rate',
                        '$lastHeartRate bpm',
                        Icons.favorite,
                        const Color(0xFFE91E63),
                      ),
                    ),
                ],
              ),
            ),

          const SizedBox(height: 16),

          // Device List
          Expanded(
            child: scanResults.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.watch_outlined,
                          size: 64,
                          color: Colors.grey[700],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No devices found',
                          style: TextStyle(color: Colors.grey[500]),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Make sure your watch is awake and nearby',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: scanResults.length,
                    itemBuilder: (context, index) {
                      final result = scanResults[index];
                      final name = result.device.platformName.isNotEmpty
                          ? result.device.platformName
                          : 'Unknown Device';
                      final isRDFit =
                          name.toLowerCase().contains('rdfit') ||
                          name.toLowerCase().contains('h4');

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1F2E),
                          borderRadius: BorderRadius.circular(12),
                          border: isRDFit
                              ? Border.all(
                                  color: const Color(0xFF00D4AA),
                                  width: 2,
                                )
                              : null,
                        ),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isRDFit
                                ? const Color(0xFF00D4AA)
                                : Colors.grey[700],
                            child: Icon(
                              isRDFit ? Icons.watch : Icons.bluetooth,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            name,
                            style: TextStyle(
                              fontWeight: isRDFit
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            '${result.device.remoteId} • RSSI: ${result.rssi}',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 11,
                            ),
                          ),
                          trailing: ElevatedButton(
                            onPressed: isConnecting
                                ? null
                                : () => connectAndSync(result.device),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00D4AA),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                            ),
                            child: const Text('Sync'),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: isScanning || isConnecting ? null : startScan,
        backgroundColor: const Color(0xFF00D4AA),
        foregroundColor: Colors.black,
        icon: isScanning
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : const Icon(Icons.bluetooth_searching),
        label: Text(isScanning ? 'Scanning...' : 'Scan for Watch'),
      ),
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F2E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(color: Colors.grey[400], fontSize: 12),
              ),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
