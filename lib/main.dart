import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const MijozSignalApp());
}

class MijozSignalApp extends StatelessWidget {
  const MijozSignalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mijoz Signal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const MonitorPage(),
    );
  }
}

class MonitorPage extends StatefulWidget {
  const MonitorPage({super.key});

  @override
  State<MonitorPage> createState() => _MonitorPageState();
}

class _MonitorPageState extends State<MonitorPage>
    with WidgetsBindingObserver {
  // ---------- Sozlamalar ----------
  static const String _alertText = 'Mijoz keldi! Mijoz keldi!';
  static const int _frameIntervalMs = 150;
  static const double _moveThreshold = 0.012;
  static const int _moveHoldMs = 1200;
  static const int _rearmAbsentMs = 2000;

  Rect _roi = const Rect.fromLTWH(0.15, 0.20, 0.70, 0.70);
  int _cooldownSec = 6;

  // ---------- Holat ----------
  CameraController? _controller;
  CameraDescription? _camera;
  final FlutterTts _tts = FlutterTts();
  final PoseDetector _detector = PoseDetector(
    options: PoseDetectorOptions(
      mode: PoseDetectionMode.stream,
      model: PoseDetectionModel.base,
    ),
  );

  bool _monitoring = true;
  bool _busy = false;
  bool _cameraReady = false;
  String _status = 'Kamera ishga tushirilmoqda...';
  String? _error;

  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAlert = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastInside = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);
  Offset? _prevCenter;
  Offset? _center;
  bool _armed = true;
  bool _insideNow = false;
  int _alertCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _initTts();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _disposeCamera();
    _detector.close();
    _tts.stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null) _initCamera();
    }
  }

  // ---------- TTS ----------
  Future<void> _initTts() async {
    String lang = 'uz-UZ';
    try {
      final uz = await _tts.isLanguageAvailable('uz-UZ');
      if (!(uz == true || uz == 1)) {
        final tr = await _tts.isLanguageAvailable('tr-TR');
        lang = (tr == true || tr == 1) ? 'tr-TR' : 'en-US';
      }
    } catch (_) {
      lang = 'en-US';
    }
    try {
      await _tts.setLanguage(lang);
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {}
  }

  Future<void> _speak() async {
    try {
      await _tts.stop();
      await _tts.speak(_alertText);
    } catch (_) {}
  }

  // ---------- Kamera ----------
  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _error = 'Kamera ruxsati berilmagan. Sozlamalardan ruxsat bering.';
      });
      return;
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() => _error = 'Kamera topilmadi.');
        return;
      }
      _camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await controller.startImageStream(_processFrame);

      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraReady = true;
        _error = null;
        _status = 'Kuzatilmoqda...';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Kamerani ishga tushirib bo\'lmadi: $e');
    }
  }

  Future<void> _disposeCamera() async {
    final c = _controller;
    _controller = null;
    _cameraReady = false;
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      try {
        await c.dispose();
      } catch (_) {}
    }
  }

  // ---------- Kadrni qayta ishlash ----------
  InputImage? _toInputImage(CameraImage image) {
    final cam = _camera;
    if (cam == null) return null;

    final rotation = InputImageRotationValue.fromRawValue(cam.sensorOrientation);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format != InputImageFormat.nv21 || image.planes.length != 1) {
      return null;
    }

    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_busy || !_monitoring) return;
    final now = DateTime.now();
    if (now.difference(_lastProcessed).inMilliseconds < _frameIntervalMs) {
      return;
    }
    _busy = true;
    _lastProcessed = now;

    try {
      final input = _toInputImage(image);
      if (input == null) return;

      final rot = _camera!.sensorOrientation;
      final bool swap = rot == 90 || rot == 270;
      final double w = (swap ? image.height : image.width).toDouble();
      final double h = (swap ? image.width : image.height).toDouble();

      final poses = await _detector.processImage(input);

      Offset? center;
      if (poses.isNotEmpty) {
        center = _personCenter(poses.first, w, h);
      }
      _evaluate(center, DateTime.now());
    } catch (_) {
      // Bitta kadrdagi xato dasturni to'xtatmasligi kerak
    } finally {
      _busy = false;
    }
  }

  Offset? _personCenter(Pose pose, double w, double h) {
    final lm = pose.landmarks;
    const keyTypes = [
      PoseLandmarkType.leftShoulder,
      PoseLandmarkType.rightShoulder,
      PoseLandmarkType.leftHip,
      PoseLandmarkType.rightHip,
      PoseLandmarkType.nose,
    ];

    final pts = <Offset>[];
    for (final t in keyTypes) {
      final p = lm[t];
      if (p != null && p.likelihood > 0.4) {
        pts.add(Offset(p.x, p.y));
      }
    }
    if (pts.isEmpty) {
      for (final p in lm.values) {
        if (p.likelihood > 0.5) pts.add(Offset(p.x, p.y));
      }
    }
    if (pts.isEmpty) return null;

    double sx = 0, sy = 0;
    for (final p in pts) {
      sx += p.dx;
      sy += p.dy;
    }
    final cx = (sx / pts.length) / w;
    final cy = (sy / pts.length) / h;
    return Offset(cx.clamp(0.0, 1.0), cy.clamp(0.0, 1.0));
  }

  void _evaluate(Offset? center, DateTime now) {
    bool inside = false;
    bool moving = false;

    if (center != null) {
      inside = _roi.contains(center);

      if (_prevCenter != null &&
          (center - _prevCenter!).distance > _moveThreshold) {
        _lastMove = now;
      }
      _prevCenter = center;
      moving = now.difference(_lastMove).inMilliseconds < _moveHoldMs;
    } else {
      _prevCenter = null;
    }

    if (inside) {
      if (now.difference(_lastInside).inMilliseconds > _rearmAbsentMs) {
        _armed = true;
      }
      _lastInside = now;
    }

    final cooldownOk = now.difference(_lastAlert).inSeconds >= _cooldownSec;

    String status;
    if (center == null) {
      status = 'Odam yo\'q';
    } else if (!inside) {
      status = 'Odam bor, lekin do\'kon zonasidan tashqarida';
    } else if (!moving) {
      status = 'Zonada, harakatsiz';
    } else {
      status = 'Zonada, harakatda';
    }

    if (inside && moving && _armed && cooldownOk) {
      _lastAlert = now;
      _armed = false;
      _alertCount++;
      status = 'MIJOZ KELDI!';
      _speak();
    }

    if (!mounted) return;
    setState(() {
      _center = center;
      _insideNow = inside;
      _status = status;
    });
  }

  // ---------- Sozlamalar oynasi ----------
  void _openSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            double l = _roi.left;
            double t = _roi.top;
            double w = _roi.width;
            double h = _roi.height;

            void apply(double nl, double nt, double nw, double nh) {
              nl = nl.clamp(0.0, 0.85);
              nt = nt.clamp(0.0, 0.85);
              nw = nw.clamp(0.1, 1.0 - nl);
              nh = nh.clamp(0.1, 1.0 - nt);
              setState(() => _roi = Rect.fromLTWH(nl, nt, nw, nh));
              setSheet(() {});
            }

            Widget slider(String label, double value, double min, double max,
                ValueChanged<double> onChanged) {
              return Row(
                children: [
                  SizedBox(width: 110, child: Text(label)),
                  Expanded(
                    child: Slider(
                      value: value.clamp(min, max),
                      min: min,
                      max: max,
                      onChanged: onChanged,
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(value.toStringAsFixed(2)),
                  ),
                ],
              );
            }

            return Padding(
              padding: EdgeInsets.fromLTRB(
                  16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Do\'kon zonasi (ROI)',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  slider('Chap', l, 0.0, 0.85, (v) => apply(v, t, w, h)),
                  slider('Yuqori', t, 0.0, 0.85, (v) => apply(l, v, w, h)),
                  slider('Kenglik', w, 0.1, 1.0, (v) => apply(l, t, v, h)),
                  slider('Balandlik', h, 0.1, 1.0, (v) => apply(l, t, w, v)),
                  const Divider(),
                  Row(
                    children: [
                      const SizedBox(width: 110, child: Text('Cooldown (s)')),
                      Expanded(
                        child: Slider(
                          value: _cooldownSec.toDouble(),
                          min: 5,
                          max: 20,
                          divisions: 15,
                          label: '$_cooldownSec s',
                          onChanged: (v) {
                            setState(() => _cooldownSec = v.round());
                            setSheet(() {});
                          },
                        ),
                      ),
                      SizedBox(width: 44, child: Text('$_cooldownSec s')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _speak,
                    icon: const Icon(Icons.volume_up),
                    label: const Text('Ovozni sinash'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildPreview()),
            _buildPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  setState(() => _error = null);
                  _initCamera();
                },
                child: const Text('Qayta urinish'),
              ),
              TextButton(
                onPressed: openAppSettings,
                child: const Text('Ilova sozlamalari'),
              ),
            ],
          ),
        ),
      );
    }

    final c = _controller;
    if (!_cameraReady || c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Center(
      child: AspectRatio(
        aspectRatio: 1 / c.value.aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(c),
            CustomPaint(
              painter: _OverlayPainter(
                roi: _roi,
                center: _center,
                inside: _insideNow,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel() {
    final Color statusColor = _status == 'MIJOZ KELDI!'
        ? Colors.redAccent
        : (_insideNow ? Colors.greenAccent : Colors.white70);

    return Container(
      width: double.infinity,
      color: Colors.grey[900],
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _status,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: statusColor),
          ),
          const SizedBox(height: 4),
          Text('Signallar soni: $_alertCount   |   Cooldown: $_cooldownSec s',
              style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Row(
                children: [
                  const Text('Kuzatuv'),
                  Switch(
                    value: _monitoring,
                    onChanged: (v) {
                      setState(() {
                        _monitoring = v;
                        if (!v) {
                          _status = 'Kuzatuv to\'xtatilgan';
                          _center = null;
                          _insideNow = false;
                        } else {
                          _status = 'Kuzatilmoqda...';
                        }
                      });
                    },
                  ),
                ],
              ),
              OutlinedButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.tune),
                label: const Text('Zona / Sozlama'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.roi,
    required this.center,
    required this.inside,
  });

  final Rect roi;
  final Offset? center;
  final bool inside;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      roi.left * size.width,
      roi.top * size.height,
      roi.width * size.width,
      roi.height * size.height,
    );

    final fill = Paint()
      ..color = (inside ? Colors.green : Colors.blue).withOpacity(0.15)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = inside ? Colors.greenAccent : Colors.lightBlueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawRect(rect, fill);
    canvas.drawRect(rect, border);

    if (center != null) {
      final dot = Paint()
        ..color = inside ? Colors.greenAccent : Colors.orangeAccent;
      canvas.drawCircle(
        Offset(center!.dx * size.width, center!.dy * size.height),
        math.max(8, size.width * 0.02),
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      old.roi != roi || old.center != center || old.inside != inside;
}
