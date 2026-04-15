import 'dart:ui' as ui;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:screenshot/screenshot.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    print("Firebase Config Warning: $e");
  }
  runApp(const MyApp());
}

enum DrawingMode { pen, eraser, line, rect, circle }

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Đồ Án Nhóm 8 - Pro Draw Studio',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.light),
        useMaterial3: true,
      ),
      home: const DrawingBoard(),
    );
  }
}

// 1. MODEL NGHIỆP VỤ: STROKE (Nét vẽ)
class Stroke {
  final List<Offset> points;
  final ui.Color color;
  final double width;
  final double opacity;
  final DrawingMode mode;

  Stroke({required this.points, required this.color, required this.width, required this.opacity, required this.mode});

  Map<String, dynamic> toMap() => {
    'points': points.map((p) => {'dx': p.dx, 'dy': p.dy}).toList(),
    'color': color.value,
    'width': width,
    'opacity': opacity,
    'mode': mode.index,
  };

  factory Stroke.fromMap(Map<String, dynamic> map) => Stroke(
    points: (map['points'] as List).map((p) => Offset(p['dx'], p['dy'])).toList(),
    color: Color(map['color']),
    width: map['width'],
    opacity: map['opacity'],
    mode: DrawingMode.values[map['mode']],
  );
}

// 2. MODEL NGHIỆP VỤ: LAYER (Lớp vẽ)
class DrawingLayer {
  String name;
  bool isVisible;
  List<Stroke> strokes;

  DrawingLayer({required this.name, this.isVisible = true, List<Stroke>? strokes}) 
      : strokes = strokes ?? [];

  Map<String, dynamic> toMap() => {
    'name': name,
    'isVisible': isVisible,
    'strokes': strokes.map((s) => s.toMap()).toList(),
  };

  factory DrawingLayer.fromMap(Map<String, dynamic> map) => DrawingLayer(
    name: map['name'],
    isVisible: map['isVisible'],
    strokes: (map['strokes'] as List).map((s) => Stroke.fromMap(s)).toList(),
  );
}

class DrawingBoard extends StatefulWidget {
  const DrawingBoard({super.key});

  @override
  State<DrawingBoard> createState() => _DrawingBoardState();
}

class _DrawingBoardState extends State<DrawingBoard> {
  // QUẢN LÝ DỮ LIỆU ĐA LỚP (LAYER SYSTEM)
  List<DrawingLayer> layers = [DrawingLayer(name: "Lớp Cơ Bản")];
  int activeLayerIndex = 0;
  
  List<DrawingLayer> redoStack = [];
  List<Offset> currentPoints = [];
  
  ui.Color selectedColor = Colors.black;
  ui.Color backgroundColor = Colors.white;
  double strokeWidth = 5.0;
  double opacity = 1.0;
  DrawingMode currentMode = DrawingMode.pen;

  User? _user;
  final ScreenshotController screenshotController = ScreenshotController();

  @override
  void initState() {
    super.initState();
    _checkCurrentUser();
    _loadProjectOffline();
  }

  void _checkCurrentUser() {
    FirebaseAuth.instance.authStateChanges().listen((user) => setState(() => _user = user));
  }

  // NGHIỆP VỤ LƯU TRỮ: MULTI-LAYER PERSISTENCE
  Future<void> _saveProjectOffline() async {
    final prefs = await SharedPreferences.getInstance();
    final data = layers.map((l) => l.toMap()).toList();
    await prefs.setString('project_layers_data_v6', jsonEncode(data));
  }

  Future<void> _loadProjectOffline() async {
    final prefs = await SharedPreferences.getInstance();
    final dataStr = prefs.getString('project_layers_data_v6');
    if (dataStr != null) {
      final List<dynamic> data = jsonDecode(dataStr);
      setState(() {
        layers = data.map((l) => DrawingLayer.fromMap(l)).toList();
        activeLayerIndex = 0;
      });
    }
  }

  void _onPanStart(DragStartDetails details) {
    if (!layers[activeLayerIndex].isVisible) return; // Không vẽ trên lớp đang ẩn
    setState(() {
      redoStack.clear();
      RenderBox renderBox = context.findRenderObject() as RenderBox;
      currentPoints = [renderBox.globalToLocal(details.globalPosition)];
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!layers[activeLayerIndex].isVisible) return;
    setState(() {
      RenderBox renderBox = context.findRenderObject() as RenderBox;
      Offset point = renderBox.globalToLocal(details.globalPosition);
      if (currentMode == DrawingMode.pen || currentMode == DrawingMode.eraser) {
        currentPoints.add(point);
      } else {
        if (currentPoints.length > 1) currentPoints[1] = point;
        else currentPoints.add(point);
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (!layers[activeLayerIndex].isVisible) return;
    setState(() {
      if (currentPoints.isNotEmpty) {
        layers[activeLayerIndex].strokes.add(Stroke(
          points: List.from(currentPoints),
          color: currentMode == DrawingMode.eraser ? backgroundColor : selectedColor,
          width: strokeWidth,
          opacity: currentMode == DrawingMode.eraser ? 1.0 : opacity,
          mode: currentMode,
        ));
      }
      currentPoints.clear();
      _saveProjectOffline();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: Stack(
        children: [
          // CANVAS ZONE
          Screenshot(
            controller: screenshotController,
            child: Container(
              color: backgroundColor,
              child: GestureDetector(
                onPanStart: _onPanStart,
                onPanUpdate: _onPanUpdate,
                onPanEnd: _onPanEnd,
                child: RepaintBoundary( // TỐI ƯU HIỆU NĂNG RENDER
                  child: CustomPaint(
                    painter: DrawingPainter(
                      layers: layers,
                      currentPoints: currentPoints,
                      currentColor: selectedColor,
                      currentWidth: strokeWidth,
                      currentOpacity: opacity,
                      currentMode: currentMode,
                    ),
                    size: Size.infinite,
                  ),
                ),
              ),
            ),
          ),
          _buildFloatingHeader(),
          _buildBottomControlCenter(),
        ],
      ),
    );
  }

  Widget _buildFloatingHeader() {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              // MODULE NGƯỜI DÙNG
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.85), borderRadius: BorderRadius.circular(30), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]),
                child: Row(
                  children: [
                    _user == null 
                      ? IconButton(icon: const Icon(Icons.account_circle, color: Colors.deepPurple), onPressed: () {})
                      : CircleAvatar(radius: 16, backgroundImage: NetworkImage(_user!.photoURL ?? "")),
                    if (_user != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(_user!.displayName!.split(' ')[0], style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
                  ],
                ),
              ),
              const Spacer(),
              // NHÓM NÚT HÀNH ĐỘNG
              Container(
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.85), borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)]),
                child: Row(
                  children: [
                    _actionIcon(Icons.undo, _undo, layers[activeLayerIndex].strokes.isNotEmpty),
                    _actionIcon(Icons.redo, _redo, redoStack.isNotEmpty),
                    _actionIcon(Icons.share, _shareImage, true),
                    _actionIcon(Icons.download, _saveImage, true),
                    _actionIcon(Icons.delete_sweep, _clear, true, isRed: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionIcon(IconData icon, ui.VoidCallback onTap, bool enabled, {bool isRed = false}) => IconButton(
    visualDensity: VisualDensity.compact,
    icon: Icon(icon, size: 20, color: enabled ? (isRed ? Colors.redAccent : Colors.deepPurple) : Colors.grey[300]),
    onPressed: enabled ? onTap : null,
  );

  Widget _buildBottomControlCenter() {
    return Positioned(
      bottom: 20, left: 12, right: 12,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildBackgroundSelector(),
            const SizedBox(height: 10),
            Card(
              elevation: 10,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
              child: DefaultTabController(
                length: 4,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const TabBar(
                      labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      tabs: [
                        Tab(icon: Icon(Icons.brush, size: 18), text: 'Cọ'),
                        Tab(icon: Icon(Icons.category, size: 18), text: 'Hình'),
                        Tab(icon: Icon(Icons.layers, size: 18), text: 'Lớp'),
                        Tab(icon: Icon(Icons.palette, size: 18), text: 'Màu'),
                      ],
                    ),
                    SizedBox(
                      height: 160,
                      child: TabBarView(
                        children: [
                          _buildBrushTab(),
                          _buildShapesTab(),
                          _buildLayersTab(),
                          _buildColorTab(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLayersTab() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: layers.length,
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
            itemBuilder: (context, index) {
              bool isActive = activeLayerIndex == index;
              return GestureDetector(
                onTap: () => setState(() => activeLayerIndex = index),
                child: Container(
                  width: 80,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: isActive ? Colors.deepPurple.withOpacity(0.1) : Colors.grey[50],
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: isActive ? Colors.deepPurple : Colors.transparent, width: 2),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: Icon(layers[index].isVisible ? Icons.visibility : Icons.visibility_off, size: 18),
                        onPressed: () => setState(() => layers[index].isVisible = !layers[index].isVisible),
                      ),
                      Text(layers[index].name, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        TextButton.icon(
          onPressed: () => setState(() { layers.insert(0, DrawingLayer(name: "Lớp ${layers.length + 1}")); activeLayerIndex = 0; }),
          icon: const Icon(Icons.add_circle_outline, size: 18),
          label: const Text("Thêm lớp mới", style: TextStyle(fontSize: 12)),
        )
      ],
    );
  }

  // --- NGHIỆP VỤ LOGIC ---

  void _undo() {
    if (layers[activeLayerIndex].strokes.isNotEmpty) {
      setState(() {
        final last = layers[activeLayerIndex].strokes.removeLast();
        redoStack.add(DrawingLayer(name: "", strokes: [last]));
        _saveProjectOffline();
      });
    }
  }

  void _redo() {
    if (redoStack.isNotEmpty) {
      setState(() {
        final last = redoStack.removeLast().strokes.first;
        layers[activeLayerIndex].strokes.add(last);
        _saveProjectOffline();
      });
    }
  }

  void _clear() {
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Xóa project?"),
        content: const Text("Hành động này sẽ làm mới toàn bộ các lớp vẽ hiện tại."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text("Hủy")),
          TextButton(onPressed: () {
            setState(() { layers = [DrawingLayer(name: "Lớp 1")]; activeLayerIndex = 0; redoStack.clear(); });
            _saveProjectOffline();
            Navigator.pop(c);
          }, child: const Text("Xóa sạch", style: TextStyle(color: Colors.red))),
        ],
      ),
    );
  }

  Future<void> _saveImage() async {
    final image = await screenshotController.capture();
    if (image != null) {
      await ImageGallerySaver.saveImage(image, name: "Project_Nhom8_${DateTime.now().millisecond}");
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Đã lưu vào bộ sưu tập!")));
    }
  }

  Future<void> _shareImage() async {
    final image = await screenshotController.capture();
    if (image != null) {
      final dir = await getTemporaryDirectory();
      final file = await File('${dir.path}/art.png').create();
      await file.writeAsBytes(image);
      await Share.shareXFiles([XFile(file.path)], text: 'Xem tác phẩm của Nhóm 8');
    }
  }

  // UI CON
  Widget _buildBrushTab() => Padding(
    padding: const EdgeInsets.all(15.0),
    child: Column(children: [
      _sliderRow(Icons.line_weight, strokeWidth, 1, 50, (v) => setState(() => strokeWidth = v)),
      _sliderRow(Icons.opacity, opacity, 0.1, 1.0, (v) => setState(() => opacity = v), isPercent: true),
    ]),
  );

  Widget _buildShapesTab() => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
    _shapeBtn(Icons.gesture, DrawingMode.pen, "Cọ"),
    _shapeBtn(Icons.horizontal_rule, DrawingMode.line, "Thẳng"),
    _shapeBtn(Icons.crop_square, DrawingMode.rect, "Vuông"),
    _shapeBtn(Icons.panorama_fish_eye, DrawingMode.circle, "Tròn"),
    _shapeBtn(Icons.auto_fix_high, DrawingMode.eraser, "Tẩy"),
  ]);

  Widget _buildColorTab() {
    final colors = [Colors.black, Colors.red, Colors.blue, Colors.green, Colors.orange, Colors.purple, Colors.pink, Colors.brown, Colors.teal, Colors.grey];
    return GridView.builder(
      padding: const EdgeInsets.all(15),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 6, crossAxisSpacing: 10, mainAxisSpacing: 10),
      itemCount: colors.length,
      itemBuilder: (context, i) => GestureDetector(
        onTap: () => setState(() { selectedColor = colors[i]; currentMode = DrawingMode.pen; }),
        child: Container(
          decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle, border: Border.all(color: selectedColor == colors[i] ? Colors.deepPurple : Colors.white, width: 3)),
        ),
      ),
    );
  }

  Widget _sliderRow(IconData icon, double val, double min, double max, Function(double) onChg, {bool isPercent = false}) => Row(children: [
    Icon(icon, size: 20), Expanded(child: Slider(value: val, min: min, max: max, onChanged: onChg)),
    Text(isPercent ? "${(val*100).toInt()}%" : val.toInt().toString(), style: const TextStyle(fontSize: 10)),
  ]);

  Widget _shapeBtn(IconData icon, DrawingMode mode, String label) => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
    IconButton(icon: Icon(icon, color: currentMode == mode ? Colors.deepPurple : Colors.grey, size: 20), onPressed: () => setState(() => currentMode = mode)),
    Text(label, style: TextStyle(fontSize: 9, color: currentMode == mode ? Colors.deepPurple : Colors.grey)),
  ]);

  Widget _buildBackgroundSelector() => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
    Colors.white, Colors.grey[200]!, Colors.blueGrey[900]!, Colors.amber[50]!
  ].map((c) => GestureDetector(
    onTap: () => setState(() => backgroundColor = c),
    child: Container(margin: const EdgeInsets.symmetric(horizontal: 5), width: 22, height: 22, decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.grey, width: 1))),
  )).toList());
}

// LỚP VẼ NGHIỆP VỤ (MULTI-LAYER PAINTER)
class DrawingPainter extends CustomPainter {
  final List<DrawingLayer> layers;
  final List<Offset> currentPoints;
  final ui.Color currentColor;
  final double currentWidth;
  final double currentOpacity;
  final DrawingMode currentMode;

  DrawingPainter({required this.layers, required this.currentPoints, required this.currentColor, required this.currentWidth, required this.currentOpacity, required this.currentMode});

  @override
  void paint(Canvas canvas, Size size) {
    // VẼ TỪ LỚP DƯỚI LÊN TRÊN
    for (var layer in layers.reversed) {
      if (!layer.isVisible) continue;
      for (var stroke in layer.strokes) {
        final paint = Paint()..color = stroke.color.withOpacity(stroke.opacity)..strokeWidth = stroke.width..strokeCap = StrokeCap.round..strokeJoin = ui.StrokeJoin.round..style = ui.PaintingStyle.stroke;
        _drawShape(canvas, stroke.points, paint, stroke.mode);
      }
    }

    // VẼ NÉT ĐANG VẼ TRÊN LỚP HIỆN TẠI
    if (currentPoints.isNotEmpty) {
      final paint = Paint()..color = currentMode == DrawingMode.eraser ? Colors.grey.withOpacity(0.3) : currentColor.withOpacity(currentOpacity)..strokeWidth = currentWidth..strokeCap = StrokeCap.round..strokeJoin = ui.StrokeJoin.round..style = ui.PaintingStyle.stroke;
      _drawShape(canvas, currentPoints, paint, currentMode);
    }
  }

  void _drawShape(ui.Canvas canvas, List<ui.Offset> points, ui.Paint paint, DrawingMode mode) {
    if (points.isEmpty) return;
    if (mode == DrawingMode.pen || mode == DrawingMode.eraser) {
      final path = ui.Path();
      path.moveTo(points[0].dx, points[0].dy);
      for (int i = 1; i < points.length - 1; i++) {
        final mid = ui.Offset((points[i].dx + points[i + 1].dx) / 2, (points[i].dy + points[i + 1].dy) / 2);
        path.quadraticBezierTo(points[i].dx, points[i].dy, mid.dx, mid.dy);
      }
      if (points.length > 1) path.lineTo(points.last.dx, points.last.dy);
      canvas.drawPath(path, paint);
    } else if (points.length > 1) {
      if (mode == DrawingMode.line) canvas.drawLine(points[0], points[1], paint);
      else if (mode == DrawingMode.rect) canvas.drawRect(ui.Rect.fromPoints(points[0], points[1]), paint);
      else if (mode == DrawingMode.circle) canvas.drawCircle(points[0], (points[1] - points[0]).distance, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DrawingPainter old) => true;
}
