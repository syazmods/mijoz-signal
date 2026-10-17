import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';

final File _logFile = File('${Directory.systemTemp.path}/diag_log.txt');

void logLine(String s) {
  try {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    _logFile.writeAsStringSync('$t $s\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

String readLog() {
  try {
    return _logFile.existsSync() ? _logFile.readAsStringSync() : '';
  } catch (_) {
    return '';
  }
}

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError =
        (d) => logLine('FLUTTER XATO: ${d.exceptionAsString()}');
    runApp(const DiagApp());
  }, (e, st) => logLine('ZONA XATO: $e\n$st'));
}

class DiagApp extends StatelessWidget {
  const DiagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const DiagPage(),
    );
  }
}

class DiagPage extends StatefulWidget {
  const DiagPage({super.key});

  @override
  State<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends State<DiagPage> {
  String previous = '';
  String current = '';
  CameraController? cam;
  CameraDescription? backCam;
  PoseDetector? det;
  bool busy = false;
  int frames = 0;

  @override
  void initState() {
    super.initState();
    previous = readLog();
    try {
      _logFile.writeAsStringSync('');
    } catch (_) {}
    logLine('ilova ochildi');
    run();
  }

  @override
  void dispose() {
    cam?.dispose();
    det?.close();
    super.dispose();
  }

  void refresh() {
    if (mounted) setState(() => current = readLog());
  }

  Future<void> step(String name, Future<void> Function() f) async {
    logLine('BOSHLANDI: $name');
    refresh();
    try {
      await f();
      logLine('OK: $name');
    } catch (e) {
      logLine('XATO: $name -> $e');
    }
    refresh();
  }

  Future<void> run() async {
    await step('1. Kamera ruxsati', () async {
      final s = await Permission.camera.request();
      logLine('ruxsat holati: $s');
    });

    List<CameraDescription> cams = [];
    await step('2. Kameralar royxati', () async {
      cams = await availableCameras();
      logLine('kameralar soni: ${cams.length}');
    });
    if (cams.isEmpty) return;

    backCam = cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );

    await step('3. Kamerani ishga tushirish', () async {
      final c = CameraController(
        backCam!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await c.initialize();
      cam = c;
    });

    await step('4. Pose detektor yaratish', () async {
      det = PoseDetector(
        options: PoseDetectorOptions(
          mode: PoseDetectionMode.stream,
          model: PoseDetectionModel.base,
        ),
      );
    });

    await step('5. Kadr oqimi va birinchi aniqlash', () async {
      await cam!.startImageStream(onFrame);
      await Future.delayed(const Duration(seconds: 4));
    });

    await step('6. Ovoz (TTS)', () async {
      final tts = FlutterTts();
      await tts.setLanguage('en-US');
      await tts.speak('test');
    });

    logLine('HAMMASI TUGADI');
    refresh();
  }

  Future<void> onFrame(CameraImage image) async {
    if (busy || det == null) return;
    busy = true;
    try {
      final cd = backCam;
      if (cd == null) return;
      final rotation =
          InputImageRotationValue.fromRawValue(cd.sensorOrientation);
      if (rotation == null || image.planes.length != 1) {
        if (frames == 0) {
          logLine('kadr formati mos emas: planes=${image.planes.length}');
        }
        frames++;
        return;
      }
      final plane = image.planes.first;
      final input = InputImage.fromBytes(
        bytes: plane.bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: plane.bytesPerRow,
        ),
      );
      final poses = await det!.processImage(input);
      frames++;
      if (frames <= 3) logLine('kadr #$frames, odamlar: ${poses.length}');
    } catch (e) {
      logLine('kadr xato: $e');
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('OLDINGI ISHGA TUSHISH JURNALI:',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.orange)),
              Text(previous.isEmpty ? '(bosh)' : previous),
              const SizedBox(height: 20),
              const Text('HOZIRGI JURNAL:',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.greenAccent)),
              Text(current),
            ],
          ),
        ),
      ),
    );
  }
}
