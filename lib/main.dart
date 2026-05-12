import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math';

void main() => runApp(const CadApp());

class CadApp extends StatelessWidget {
  const CadApp({super.key});
  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: const CadCanvas(), theme: ThemeData.dark());
}

class Line {
  Offset start;
  Offset end;
  Line(this.start, this.end);

  Line copy() => Line(start, end);
}

// ============ INTENTS (DEFINITIONS) =============
class UndoIntent extends Intent {}

class RedoIntent extends Intent {}

class DeleteIntent extends Intent {}
// ================================================

class CadCanvas extends StatefulWidget {
  const CadCanvas({super.key});
  @override
  State<CadCanvas> createState() => _CadCanvasState();
}

class _CadCanvasState extends State<CadCanvas> {
  List<Line> lines = [];
  bool _isInputValid = true;
  late FocusNode _keyboardFocusNode;

  List<List<Line>> _undoStack = [];
  List<List<Line>> _redoStack = [];
  List<Line> profilePreviewLines = [];
  List<Line> profileLongitudinalLines = [];
  // Wewnątrz _CadCanvasState
  double marginX = 0.2;
  double marginY = 0.2;
  double spacingX =
      0.6; // Rozstaw profili pionowych (rozmieszczonych wzdłuż osi X)
  double spacingY =
      0.6; // Rozstaw profili poziomych (rozmieszczonych wzdłuż osi Y)

  late final TextEditingController _marginXController;
  late final TextEditingController _marginYController;
  late final TextEditingController _spacingXController;
  late final TextEditingController _spacingYController;

  // Dodaj te kontrolery w initState (opcjonalnie, by móc sterować tymi wartościami)
  double hangerMargin = 0.3; // 30 cm
  double hangerSpacing = 0.7; // 70 cm
  late final TextEditingController _hangerMarginController;
  late final TextEditingController _hangerSpacingController;
  // Funkcja pomocnicza do obliczania wieszaków na pojedynczej linii
  double plugWallMargin = 0.1; // 10 cm od ściany
  double plugSpacing = 0.4; // co 40 cm
  late final TextEditingController _plugWallMarginController;
  late final TextEditingController _plugSpacingController;

  double screwsPerMeterSq = 20.0; // Domyślna wartość
  late final TextEditingController _screwsPerMeterSqController;
  @override
  void initState() {
    super.initState();
    _gridController = TextEditingController(text: metersPerGrid.toString());
    _marginXController = TextEditingController(text: marginX.toString());
    _marginYController = TextEditingController(text: marginY.toString());
    _spacingXController = TextEditingController(text: spacingX.toString());
    _spacingYController = TextEditingController(text: spacingY.toString());
    _hangerMarginController = TextEditingController(
      text: hangerMargin.toString(),
    );
    _hangerSpacingController = TextEditingController(
      text: hangerSpacing.toString(),
    );
    _keyboardFocusNode = FocusNode()..requestFocus();
    _plugWallMarginController = TextEditingController(
      text: plugWallMargin.toString(),
    );
    _plugSpacingController = TextEditingController(
      text: plugSpacing.toString(),
    );
    _screwsPerMeterSqController = TextEditingController(
      text: screwsPerMeterSq.toString(),
    );
  }

  String calculationResult = "";

  Line? currentLine;
  Offset? _drawingStartPoint;
  int? selectedLineIndex;

  double pixelsPerMeter = 50.0;
  double metersPerGrid = 1.0;
  double snapThresholdMeters = 0.2;

  Offset cameraOffset = Offset.zero;
  bool isPanMode = false;
  bool isMoveMode = false;
  Offset? pendingStartPoint;

  late final TextEditingController _gridController;

  List<List<Offset>> closedPolygons = [];

  // ---------- Undo/Redo ----------
  void _pushState() {
    _undoStack.add(lines.map((l) => l.copy()).toList());
    _redoStack.clear();
    _computeClosedAreas();
  }

  // ---------- Closed area detection ----------
  List<List<Offset>> _computeClosedAreas() {
    List<List<Offset>> newPolygons = [];
    if (lines.isEmpty) return newPolygons;

    Offset normalize(Offset p) => Offset(
      (p.dx * 100).roundToDouble() / 100,
      (p.dy * 100).roundToDouble() / 100,
    );

    Map<Offset, List<Offset>> graph = {};
    for (var line in lines) {
      final p1 = normalize(line.start);
      final p2 = normalize(line.end);
      if (p1 == p2) continue;
      graph.putIfAbsent(p1, () => []);
      graph.putIfAbsent(p2, () => []);
      if (!graph[p1]!.contains(p2)) graph[p1]!.add(p2);
      if (!graph[p2]!.contains(p1)) graph[p2]!.add(p1);
    }

    Map<Offset, List<Offset>> adj = {};
    for (var v in graph.keys) {
      List<Offset> neighbors = List.from(graph[v]!);
      neighbors.sort((a, b) => (a - v).direction.compareTo((b - v).direction));
      adj[v] = neighbors;
    }

    Set<String> usedEdges = {};
    for (var startV in adj.keys) {
      for (var nextV in adj[startV]!) {
        String edgeKey = "${startV.dx},${startV.dy}->${nextV.dx},${nextV.dy}";
        if (usedEdges.contains(edgeKey)) continue;

        List<Offset> cycle = [startV];
        Offset current = nextV;
        Offset prev = startV;
        usedEdges.add(edgeKey);

        bool found = false;
        while (true) {
          cycle.add(current);
          List<Offset> neighbors = adj[current] ?? [];
          if (neighbors.isEmpty) break;

          int idx = neighbors.indexOf(prev);
          if (idx == -1) break;

          int nextIdx = (idx - 1 + neighbors.length) % neighbors.length;
          Offset next = neighbors[nextIdx];

          String stepKey = "${current.dx},${current.dy}->${next.dx},${next.dy}";
          if (usedEdges.contains(stepKey)) {
            if (next == startV) found = true;
            break;
          }

          usedEdges.add(stepKey);
          prev = current;
          current = next;

          if (current == startV) {
            found = true;
            break;
          }
          if (cycle.length > 100) break;
        }

        if (found && cycle.length >= 3) {
          double area = 0;
          for (int i = 0; i < cycle.length; i++) {
            final p1 = cycle[i];
            final p2 = cycle[(i + 1) % cycle.length];
            area += (p1.dx * p2.dy - p2.dx * p1.dy);
          }
          if (area.abs() > 0.01) newPolygons.add(cycle);
        }
      }
    }
    return newPolygons;
  }

  Offset _toWorld(Offset screenPos) =>
      screenPos / pixelsPerMeter + cameraOffset;

  // ---------- Snapping ----------
  Offset? _findSnapPoint(Offset touchInMeters, {int? excludeIndex}) {
    Offset? best;
    double bestDist = snapThresholdMeters;
    for (int i = 0; i < lines.length; i++) {
      if (excludeIndex != null && i == excludeIndex) continue;
      for (var p in [lines[i].start, lines[i].end]) {
        double d = (touchInMeters - p).distance;
        if (d < bestDist) {
          bestDist = d;
          best = p;
        }
      }
    }
    return best;
  }

  int _countIntersections(List<Line> previewLines) {
    int count = 0;
    List<Line> verticals = previewLines
        .where((l) => (l.start.dx - l.end.dx).abs() < 0.001)
        .toList();
    List<Line> horizontals = previewLines
        .where((l) => (l.start.dy - l.end.dy).abs() < 0.001)
        .toList();

    for (var v in verticals) {
      for (var h in horizontals) {
        double minV_Y = min(v.start.dy, v.end.dy);
        double maxV_Y = max(v.start.dy, v.end.dy);
        double minH_X = min(h.start.dx, h.end.dx);
        double maxH_X = max(h.start.dx, h.end.dx);

        // Sprawdź czy punkt przecięcia (v.x, h.y) leży na obu odcinkach
        if (h.start.dy >= minV_Y &&
            h.start.dy <= maxV_Y &&
            v.start.dx >= minH_X &&
            v.start.dx <= maxH_X) {
          count++;
        }
      }
    }
    return count;
  }

  List<double> _buildYTable({int? excludeIndex}) {
    final List<double> ys = [];
    for (int i = 0; i < lines.length; i++) {
      if (excludeIndex != null && i == excludeIndex) continue;
      ys.add(lines[i].start.dy);
      ys.add(lines[i].end.dy);
    }
    return ys;
  }

  // Wycina poziomą linię (y = const) do wnętrza wielokąta
  List<Line> _clipHorizontalLine(double y, List<Offset> poly) {
    List<double> intersections = [];
    for (int i = 0; i < poly.length; i++) {
      Offset p1 = poly[i];
      Offset p2 = poly[(i + 1) % poly.length];

      // Sprawdź, czy krawędź przecina naszą linię y
      if ((p1.dy <= y && p2.dy > y) || (p2.dy <= y && p1.dy > y)) {
        // Oblicz współrzędną X przecięcia
        double x = p1.dx + (y - p1.dy) * (p2.dx - p1.dx) / (p2.dy - p1.dy);
        intersections.add(x);
      }
    }
    intersections.sort();
    List<Line> result = [];
    // Łączymy przecięcia parami: (x0, x1), (x2, x3)...
    for (int i = 0; i < intersections.length - 1; i += 2) {
      if ((intersections[i + 1] - intersections[i]).abs() > 0.001) {
        result.add(
          Line(Offset(intersections[i], y), Offset(intersections[i + 1], y)),
        );
      }
    }
    return result;
  }

  // Wycina pionową linię (x = const) do wnętrza wielokąta
  List<Line> _clipVerticalLine(double x, List<Offset> poly) {
    List<double> intersections = [];
    for (int i = 0; i < poly.length; i++) {
      Offset p1 = poly[i];
      Offset p2 = poly[(i + 1) % poly.length];

      // Sprawdź, czy krawędź przecina naszą linię x
      if ((p1.dx <= x && p2.dx > x) || (p2.dx <= x && p1.dx > x)) {
        double y = p1.dy + (x - p1.dx) * (p2.dy - p1.dy) / (p2.dx - p1.dx);
        intersections.add(y);
      }
    }
    intersections.sort();
    List<Line> result = [];
    for (int i = 0; i < intersections.length - 1; i += 2) {
      if ((intersections[i + 1] - intersections[i]).abs() > 0.001) {
        result.add(
          Line(Offset(x, intersections[i]), Offset(x, intersections[i + 1])),
        );
      }
    }
    return result;
  }

  List<double> _buildXTable({int? excludeIndex}) {
    final List<double> xs = [];
    for (int i = 0; i < lines.length; i++) {
      if (excludeIndex != null && i == excludeIndex) continue;
      xs.add(lines[i].start.dx);
      xs.add(lines[i].end.dx);
    }
    return xs;
  }

  void _addLine(Line line) {
    _undoStack.add(lines.map((l) => l.copy()).toList());
    _redoStack.clear();
    setState(() {
      lines.add(line.copy());
      pendingStartPoint = line.end;
    });
    setState(() {
      closedPolygons = _computeClosedAreas();
    });
  }

  void _deleteSelected() {
    if (lines.isEmpty) return;
    _pushState();
    setState(() {
      if (selectedLineIndex != null) {
        lines.removeAt(selectedLineIndex!);
        selectedLineIndex = null;
      } else {
        lines.clear();
      }
      pendingStartPoint = null;
      currentLine = null;
    });
    setState(() {
      closedPolygons = _computeClosedAreas();
    });
    setState(() {
      profilePreviewLines = [];
      profileLongitudinalLines = [];
      calculationResult = "";
      closedPolygons = _computeClosedAreas();
    });
  }

  void _editLineLength(int index, double newLength) {
    _pushState();
    setState(() {
      profilePreviewLines = [];
      profileLongitudinalLines = [];
      calculationResult = "";

      Offset dir = lines[index].end - lines[index].start;
      if (dir.distance > 0) {
        lines[index].end =
            lines[index].start + (dir / dir.distance * newLength);
      }
      closedPolygons = _computeClosedAreas();
    });
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      _redoStack.add(lines.map((l) => l.copy()).toList());
      lines = _undoStack.removeLast();
      selectedLineIndex = null;
      currentLine = null;
      pendingStartPoint = null;
    });
    setState(() {
      closedPolygons = _computeClosedAreas();
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      _undoStack.add(lines.map((l) => l.copy()).toList());
      lines = _redoStack.removeLast();
      selectedLineIndex = null;
      currentLine = null;
      pendingStartPoint = null;
    });
    setState(() {
      closedPolygons = _computeClosedAreas();
    });
  }

  double? _snapFromTable(double value, List<double> table) {
    double? best;
    double bestDist = snapThresholdMeters;
    for (final v in table) {
      double dist = (v - value).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = v;
      }
    }
    return best;
  }

  void _calculateProfiles() {
    if (!_isInputValid) {
      setState(() {
        calculationResult = "BŁĄD: Podano nieprawidłową wartość liczbową!";
        profilePreviewLines = [];
      });
      return;
    }

    if (closedPolygons.isEmpty) {
      setState(() => calculationResult = "Brak zamkniętych obszarów!");
      return;
    }

    // --- DEKLARACJE ZMIENNYCH STATYSTYCZNYCH ---
    double totalLength = 0;
    int totalCount = 0;
    int totalHangers = 0;
    int totalPlugs = 0;

    // Statystyki dla profili wzdłużnych (tych co 3m)
    int longitudinalCount = 0;
    double longitudinalLength = 0;

    List<Line> newPreviewLines = [];
    List<Line> newLongitudinalLines = [];

    // Helper: Czy punkt jest wewnątrz wielokąta
    bool _isInside(Offset p, List<Offset> poly) {
      bool inside = false;
      int n = poly.length;
      for (int i = 0, j = n - 1; i < n; j = i++) {
        if (((poly[i].dy > p.dy) != (poly[j].dy > p.dy)) &&
            (p.dx <
                (poly[j].dx - poly[i].dx) *
                        (p.dy - poly[i].dy) /
                        (poly[j].dy - poly[i].dy) +
                    poly[i].dx)) {
          inside = !inside;
        }
      }
      return inside;
    }

    // Helper: Pozycje wieszaków
    List<double> _getHangerOffsets(Line line) {
      double len = (line.start - line.end).distance;
      double endMarginLimit =
          len - hangerMargin; // To jest nasze 4.58m lub 3.03m

      if (len < (hangerMargin * 2)) return [];

      List<double> offsets = [hangerMargin]; // Pierwszy punkt (0.3m)
      double currentPos = hangerMargin;

      while (currentPos + hangerSpacing <= endMarginLimit + 0.001) {
        currentPos += hangerSpacing;
        offsets.add(currentPos);
      }

      // KLUCZOWA POPRAWKA:
      // Jeśli ostatni punkt z pętli jest dalej niż np. 10cm od końca marginesu,
      // dodaj wieszak dokładnie na końcu marginesu (druga ściana).
      if ((endMarginLimit - currentPos).abs() > 0.05) {
        offsets.add(endMarginLimit);
      }

      return offsets;
    }

    // GŁÓWNY ALGORYTM GENEROWANIA POZYCJI PROFILI
    List<double> generatePositions(
      List<Offset> poly,
      bool isX,
      double margin,
      double spacing,
    ) {
      Set<double> anchorSet = {};
      int n = poly.length;
      for (int i = 0; i < n; i++) {
        Offset p1 = poly[i];
        Offset p2 = poly[(i + 1) % n];
        bool isWall = isX
            ? (p1.dx - p2.dx).abs() < 0.001
            : (p1.dy - p2.dy).abs() < 0.001;
        if (isWall) {
          double wallPos = isX ? p1.dx : p1.dy;
          double midOther = isX ? (p1.dy + p2.dy) / 2 : (p1.dx + p2.dx) / 2;
          Offset testPos = isX
              ? Offset(wallPos + 0.01, midOther)
              : Offset(midOther, wallPos + 0.01);
          Offset testNeg = isX
              ? Offset(wallPos - 0.01, midOther)
              : Offset(midOther, wallPos - 0.01);
          if (_isInside(testPos, poly)) anchorSet.add(wallPos + margin);
          if (_isInside(testNeg, poly)) anchorSet.add(wallPos - margin);
        }
      }
      List<double> anchors = anchorSet.toList()..sort();
      if (anchors.isEmpty) return [];
      List<double> finalPositions = [anchors.first];
      for (int i = 0; i < anchors.length - 1; i++) {
        double current = finalPositions.last;
        double nextAnchor = anchors[i + 1];
        double fill = current + spacing;
        while (fill < nextAnchor - 0.001) {
          finalPositions.add(fill);
          fill += spacing;
        }
        if ((finalPositions.last - nextAnchor).abs() > 0.001) {
          finalPositions.add(nextAnchor);
        }
      }
      return finalPositions;
    }

    // 1. KOŁKI NA OBWODZIE (Sciany)
    // Logika: 10cm od każdego narożnika i co 40cm pomiędzy nimi
    for (var line in lines) {
      double len = (line.start - line.end).distance;
      if (len >= (plugWallMargin * 2)) {
        // Startujemy 10cm od początku ściany
        totalPlugs++;
        double currentPos = plugWallMargin;

        // Dodajemy kołki co 40cm (plugSpacing)
        while (currentPos + plugSpacing <= len - plugWallMargin + 0.001) {
          totalPlugs++;
          currentPos += plugSpacing;
        }

        // Dodajemy kołek 10cm przed końcem ściany, jeśli pętla wyżej tam nie dotarła
        if ((len - plugWallMargin - currentPos).abs() > 0.001) {
          totalPlugs++;
        }
      } else if (len > 0.02) {
        // Dla bardzo krótkich odcinków dajemy przynajmniej jeden kołek
        totalPlugs++;
      }
    }

    // 2. PROFILE I WIESZAKI
    for (var poly in closedPolygons) {
      double area = 0;
      for (int i = 0; i < poly.length; i++) {
        area +=
            (poly[i].dx * poly[(i + 1) % poly.length].dy -
            poly[(i + 1) % poly.length].dx * poly[i].dy);
      }
      if (area <= 0) continue;

      List<double> xPositions = generatePositions(
        poly,
        true,
        marginX,
        spacingX,
      );
      List<double> yPositions = generatePositions(
        poly,
        false,
        marginY,
        spacingY,
      );

      // --- PIONOWE (Główne) ---
      List<List<Line>> verticalCols = [];
      for (double x in xPositions) {
        List<Line> segments = _clipVerticalLine(x, poly);
        verticalCols.add(segments);
        for (var seg in segments) {
          newPreviewLines.add(seg);
          totalCount++;
          totalLength += (seg.start - seg.end).distance;
        }
      }

      // --- WZDŁUŻNE DLA PIONOWYCH ---
      for (int i = 0; i < verticalCols.length - 1; i++) {
        for (var segL in verticalCols[i]) {
          double len = (segL.start - segL.end).distance;
          if (len > 3.0) {
            int count = (len / 3.0).floor();
            double step = len / (count + 1);
            for (int j = 1; j <= count; j++) {
              double curY = min(segL.start.dy, segL.end.dy) + (j * step);
              for (var segR in verticalCols[i + 1]) {
                if (curY >= min(segR.start.dy, segR.end.dy) &&
                    curY <= max(segR.start.dy, segR.end.dy)) {
                  Line wzdlozny = Line(
                    Offset(segL.start.dx, curY),
                    Offset(segR.start.dx, curY),
                  );
                  newLongitudinalLines.add(wzdlozny);
                  longitudinalCount++;
                  longitudinalLength += (wzdlozny.start.dx - wzdlozny.end.dx)
                      .abs();
                }
              }
            }
          }
        }
      }

      // --- POZIOME (Nośne) + WIESZAKI + KOŁKI ---
      List<List<Line>> horizontalRows = [];
      for (double y in yPositions) {
        List<Line> segments = _clipHorizontalLine(y, poly);
        horizontalRows.add(segments);
        for (var seg in segments) {
          double len = (seg.start - seg.end).distance;
          newPreviewLines.add(seg);
          totalCount++;
          totalLength += len;

          // Obliczanie wieszaków dla profilu
          List<double> hOffsets = _getHangerOffsets(seg);
          totalHangers += hOffsets.length;

          // NOWA LOGIKA: Każdy wieszak wymaga jednego kołka
          totalPlugs += hOffsets.length;
        }
      }

      // --- WZDŁUŻNE DLA POZIOMYCH ---
      for (int i = 0; i < horizontalRows.length - 1; i++) {
        for (var segT in horizontalRows[i]) {
          double len = (segT.start - segT.end).distance;
          if (len > 3.0) {
            int count = (len / 3.0).floor();
            double step = len / (count + 1);
            for (int j = 1; j <= count; j++) {
              double curX = min(segT.start.dx, segT.end.dx) + (j * step);
              for (var segB in horizontalRows[i + 1]) {
                if (curX >= min(segB.start.dx, segB.end.dx) &&
                    curX <= max(segB.start.dx, segB.end.dx)) {
                  Line wzdlozny = Line(
                    Offset(curX, segT.start.dy),
                    Offset(curX, segB.start.dy),
                  );
                  newLongitudinalLines.add(wzdlozny);
                  longitudinalCount++;
                  longitudinalLength += (wzdlozny.start.dy - wzdlozny.end.dy)
                      .abs();
                }
              }
            }
          }
        }
      }
    }

    double totalScrews = 0; // Licznik wkrętów
    double totalArea = 0; // Całkowita powierzchnia

    for (var poly in closedPolygons) {
      // Obliczanie pola powierzchni wielokąta (metoda sznurowadłowa)
      double area = 0;
      for (int i = 0; i < poly.length; i++) {
        area +=
            (poly[i].dx * poly[(i + 1) % poly.length].dy -
            poly[(i + 1) % poly.length].dx * poly[i].dy);
      }
      area = area.abs() / 2.0;

      if (area <= 0) continue;

      totalArea += area;
      // Liczba wkrętów dla tej figury
      totalScrews += area * screwsPerMeterSq;
    }

    int intersections = _countIntersections(newPreviewLines);

    setState(() {
      profilePreviewLines = newPreviewLines;
      profileLongitudinalLines = newLongitudinalLines;
      calculationResult = "Statystyki gotowe";
    });

    _showReportDialog(
      totalCount,
      totalLength,
      intersections,
      totalHangers,
      totalPlugs,
      longitudinalCount,
      longitudinalLength,
      totalScrews.ceil(),
      totalArea,
    );
  }

  void _showReportDialog(
    int count,
    double length,
    int cross,
    int hangers,
    int plugs,
    int longCount,
    double longLen,
    int screws,
    double area,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.analytics, color: Colors.blueAccent),
            SizedBox(width: 10),
            Text("Pełne Zestawienie"),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _resRow("Profile główne/nośne:", "$count szt."),
              _resRow("Długość gł./noś.:", "${length.toStringAsFixed(2)} m"),
              const Divider(),
              _resRow(
                "Profile wzdłużne (3m):",
                "$longCount szt.",
                color: Colors.greenAccent,
              ),
              _resRow(
                "Długość wzdłużnych:",
                "${longLen.toStringAsFixed(2)} m",
                color: Colors.greenAccent,
              ),
              const Divider(),
              _resRow("Wieszaki:", "$hangers szt.", color: Colors.cyanAccent),
              _resRow(
                "Kołki montażowe:",
                "$plugs szt.",
                color: Colors.orangeAccent,
              ),
              _resRow("Łączniki krzyżowe:", "$cross szt."),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  "Info: Kołki liczone w punktach wieszaków oraz jako uzupełnienie co 40cm.",
                  style: TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ),
              _resRow(
                "Powierzchnia całkowita:",
                "${area.toStringAsFixed(2)} m²",
              ),
              _resRow(
                "Wkręty (gwoździe):",
                "$screws szt.",
                color: Colors.yellowAccent,
              ),
              const Divider(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("ZAMKNIJ"),
          ),
        ],
      ),
    );
  }

  Widget _resRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: TextStyle(fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  // ---------- UI helpers ----------
  void _centerViewOnLines() {
    if (lines.isEmpty) return;

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (var l in lines) {
      minX = min(minX, min(l.start.dx, l.end.dx));
      minY = min(minY, min(l.start.dy, l.end.dy));
      maxX = max(maxX, max(l.start.dx, l.end.dx));
      maxY = max(maxY, max(l.start.dy, l.end.dy));
    }

    Rect bounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    Size screenSize = MediaQuery.of(context).size;

    Offset screenCenterInMeters =
        Offset(screenSize.width / 2, (screenSize.height - 160) / 2) /
        pixelsPerMeter;

    setState(() {
      cameraOffset = bounds.center - screenCenterInMeters;
    });
  }

  double _distToSegment(Offset p, Offset a, Offset b) {
    double l2 = (a - b).distanceSquared;
    if (l2 == 0) return (p - a).distance;
    double t =
        ((p.dx - a.dx) * (b.dx - a.dx) + (p.dy - a.dy) * (b.dy - a.dy)) / l2;
    t = t.clamp(0.0, 1.0);
    return (p - Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy)))
        .distance;
  }

  void _updateDynamicGrid() {
    double targetTileSizePx = 60.0;
    double rawMetersPerGrid = targetTileSizePx / pixelsPerMeter;

    double exponent = (log(rawMetersPerGrid) / ln10).floorToDouble();
    double fraction = rawMetersPerGrid / pow(10, exponent);

    double niceFraction;
    if (fraction < 1.5) {
      niceFraction = 1.0;
    } else if (fraction < 3.5) {
      niceFraction = 2.0;
    } else if (fraction < 7.5) {
      niceFraction = 5.0;
    } else {
      niceFraction = 10.0;
    }

    setState(() {
      metersPerGrid = niceFraction * pow(10, exponent);
      _gridController.text = metersPerGrid.toStringAsFixed(
        metersPerGrid < 1 ? 2 : 1,
      );
    });
  }

  void _handleTap(Offset localPos) {
    Offset touchWorld = _toWorld(localPos);
    int? foundIndex;
    for (int i = 0; i < lines.length; i++) {
      double dist = _distToSegment(touchWorld, lines[i].start, lines[i].end);
      if (dist < (12 / pixelsPerMeter)) {
        foundIndex = i;
      }
    }
    if (foundIndex != null && !isMoveMode) {
      setState(() {
        selectedLineIndex = foundIndex;
        pendingStartPoint = null;
      });
      _showEditDialog(foundIndex);
      return;
    }
    setState(() {
      selectedLineIndex = foundIndex;
      if (foundIndex != null) pendingStartPoint = null;
    });
  }

  void _showEditDialog(int index) {
    final controller = TextEditingController(
      text: (lines[index].start - lines[index].end).distance.toStringAsFixed(2),
    );

    void confirm() {
      double? val = double.tryParse(controller.text);
      if (val != null) {
        _editLineLength(index, val);
      }
      Navigator.pop(context);
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Ustaw długość (m)"),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          onSubmitted: (_) => confirm(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Anuluj"),
          ),
          ElevatedButton(onPressed: confirm, child: const Text("OK")),
        ],
      ),
    );
  }

  void _resetPendingStart() {
    setState(() => pendingStartPoint = null);
  }

  void _globalAutoMerge() {
    if (lines.isEmpty) return;
    _pushState();

    setState(() {
      const double snapThreshold = 0.15; // Tolerancja osi (15cm)
      const double joinThreshold = 0.05; // Tolerancja styku (5cm)

      List<Line> verticals = [];
      List<Line> horizontals = [];
      List<Line> others = [];

      // 1. Rozdziel i wyprostuj linie
      for (var line in lines) {
        double dx = (line.start.dx - line.end.dx).abs();
        double dy = (line.start.dy - line.end.dy).abs();
        if (dx < 0.1) {
          // Ujednolicamy X dla pionowych
          double avgX = (line.start.dx + line.end.dx) / 2;
          line.start = Offset(avgX, line.start.dy);
          line.end = Offset(avgX, line.end.dy);
          verticals.add(line);
        } else if (dy < 0.1) {
          // Ujednolicamy Y dla poziomych
          double avgY = (line.start.dy + line.end.dy) / 2;
          line.start = Offset(line.start.dx, avgY);
          line.end = Offset(line.end.dx, avgY);
          horizontals.add(line);
        } else {
          others.add(line);
        }
      }

      // 2. Funkcja pomocnicza do łączenia segmentów na jednej osi
      List<Line> mergeSegments(List<Line> segmentList, bool isVertical) {
        if (segmentList.isEmpty) return [];

        // Grupowanie po współrzędnej osi (X dla pionowych, Y dla poziomych)
        List<Line> merged = [];
        while (segmentList.isNotEmpty) {
          Line base = segmentList.removeAt(0);
          double baseCoord = isVertical ? base.start.dx : base.start.dy;

          // Wyciągamy wszystkie linie leżące na tej samej osi (+/- threshold)
          List<Line> colinear = [base];
          segmentList.removeWhere((l) {
            double coord = isVertical ? l.start.dx : l.start.dy;
            if ((coord - baseCoord).abs() < snapThreshold) {
              colinear.add(l);
              return true;
            }
            return false;
          });

          // Łączymy segmenty na tej osi
          if (isVertical) {
            colinear.sort(
              (a, b) => min(
                a.start.dy,
                a.end.dy,
              ).compareTo(min(b.start.dy, b.end.dy)),
            );
          } else {
            colinear.sort(
              (a, b) => min(
                a.start.dx,
                a.end.dx,
              ).compareTo(min(b.start.dx, b.end.dx)),
            );
          }

          Line current = colinear[0];
          for (int i = 1; i < colinear.length; i++) {
            Line next = colinear[i];
            double gap = isVertical
                ? (min(next.start.dy, next.end.dy) -
                      max(current.start.dy, current.end.dy))
                : (min(next.start.dx, next.end.dx) -
                      max(current.start.dx, current.end.dx));

            if (gap < joinThreshold) {
              // Łączymy (rozciągamy current)
              if (isVertical) {
                double minY = min(
                  min(current.start.dy, current.end.dy),
                  min(next.start.dy, next.end.dy),
                );
                double maxY = max(
                  max(current.start.dy, current.end.dy),
                  max(next.start.dy, next.end.dy),
                );
                current = Line(
                  Offset(baseCoord, minY),
                  Offset(baseCoord, maxY),
                );
              } else {
                double minX = min(
                  min(current.start.dx, current.end.dx),
                  min(next.start.dx, next.end.dx),
                );
                double maxX = max(
                  max(current.start.dx, current.end.dx),
                  max(next.start.dx, next.end.dx),
                );
                current = Line(
                  Offset(minX, baseCoord),
                  Offset(maxX, baseCoord),
                );
              }
            } else {
              merged.add(current);
              current = next;
            }
          }
          merged.add(current);
        }
        return merged;
      }

      // 3. Wykonaj łączenie i zaktualizuj listę
      lines = [
        ...others,
        ...mergeSegments(verticals, true),
        ...mergeSegments(horizontals, false),
      ];

      selectedLineIndex = null;
      closedPolygons = _computeClosedAreas();
      calculationResult = "Automatycznie zsumowano ściany.";
    });
  }

  @override
  void dispose() {
    _keyboardFocusNode.dispose();

    _gridController.dispose();
    _marginXController.dispose();
    _marginYController.dispose();
    _spacingXController.dispose();
    _spacingYController.dispose();
    _hangerMarginController.dispose();
    _hangerSpacingController.dispose();
    _plugWallMarginController.dispose();
    _plugSpacingController.dispose();
    _screwsPerMeterSqController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CAD: Profile i Skala'),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.align_horizontal_left,
              color: Colors.greenAccent,
            ),
            tooltip: "Wyrównaj ściany",
            onPressed: _globalAutoMerge,
          ),
          IconButton(icon: const Icon(Icons.undo), onPressed: _undo),
          IconButton(icon: const Icon(Icons.redo), onPressed: _redo),
          IconButton(
            icon: Icon(
              isMoveMode ? Icons.open_with : Icons.straighten,
              color: isMoveMode ? Colors.orangeAccent : Colors.lightBlueAccent,
            ),
            onPressed: () => setState(() {
              isMoveMode = !isMoveMode;
              selectedLineIndex = null;
            }),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _deleteSelected,
          ),
          IconButton(
            icon: Icon(isPanMode ? Icons.pan_tool : Icons.pan_tool_outlined),
            onPressed: () => setState(() => isPanMode = !isPanMode),
          ),
          IconButton(
            icon: const Icon(Icons.center_focus_strong),
            onPressed: _centerViewOnLines,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _resetPendingStart,
          ),
        ],
      ),
      drawer: Drawer(
        child: Container(
          color: Colors.blueGrey[900],
          padding: const EdgeInsets.all(16),
          child: ListView(
            children: [
              const DrawerHeader(
                child: Center(child: Text("USTAWIENIA MONTAŻU")),
              ),

              const Text(
                "Wieszaki (Profile)",
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                "Pierwszy wieszak (m)",
                _hangerMarginController,
                (v) => hangerMargin = v,
              ),
              _buildSideInput(
                "Rozstaw wieszaków (m)",
                _hangerSpacingController,
                (v) => hangerSpacing = v,
              ),

              const Divider(height: 40),

              const Text(
                "Kołki montażowe",
                style: TextStyle(
                  color: Colors.pinkAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                "Max dystans kołka (m)",
                _plugSpacingController,
                (v) => plugSpacing = v,
              ),
              _buildSideInput(
                "Kołek od ściany (m)",
                _plugWallMarginController,
                (v) => plugWallMargin = v,
              ),

              const SizedBox(height: 30),
              ElevatedButton.icon(
                onPressed: () {
                  _calculateProfiles();
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.refresh),
                label: const Text("Zastosuj i przelicz"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                ),
              ),
              // Wewnątrz ListView w Drawerze
              const SizedBox(height: 30),
              const Text(
                "Płyty i Wkręty",
                style: TextStyle(
                  color: Colors.yellowAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                "Wkręty na m²",
                _screwsPerMeterSqController,
                (v) => screwsPerMeterSq = v,
              ),
            ],
          ),
        ),
      ),
      body: RawKeyboardListener(
        focusNode: _keyboardFocusNode,
        onKey: (RawKeyEvent event) {
          if (event is RawKeyDownEvent) {
            // Sprawdź, czy focus jest na polu tekstowym
            final focus = FocusManager.instance.primaryFocus;
            final isEditingText =
                focus?.context?.widget is EditableText ||
                focus?.context?.findAncestorWidgetOfExactType<TextField>() !=
                    null;

            // Jeśli edytujemy tekst – nie przechwytuj skrótów
            if (isEditingText) return;

            // Ctrl+Z – Undo
            if (HardwareKeyboard.instance.isControlPressed &&
                event.logicalKey == LogicalKeyboardKey.keyZ) {
              _undo();
              return;
            }

            // Ctrl+Y – Redo
            if (HardwareKeyboard.instance.isControlPressed &&
                event.logicalKey == LogicalKeyboardKey.keyY) {
              _redo();
              return;
            }

            // Backspace / Delete – usuń linię
            if (event.logicalKey == LogicalKeyboardKey.backspace ||
                event.logicalKey == LogicalKeyboardKey.delete) {
              _deleteSelected();
              return;
            }
          }
        },
        child: Column(
          children: [
            // PANEL GÓRNY – parametry profili
            // PANEL GÓRNY – parametry profili
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.blueGrey[900],
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildTopInput(
                      "Marg. Pion (X)",
                      _marginXController,
                      (v) => marginX = v,
                    ),
                    const SizedBox(width: 8),
                    _buildTopInput(
                      "Rozst. Pion (X)",
                      _spacingXController,
                      (v) => spacingX = v,
                    ),
                    const SizedBox(width: 12),
                    const SizedBox(
                      height: 30,
                      child: VerticalDivider(color: Colors.white24),
                    ),
                    const SizedBox(width: 12),
                    _buildTopInput(
                      "Marg. Poz (Y)",
                      _marginYController,
                      (v) => marginY = v,
                    ),
                    const SizedBox(width: 8),
                    _buildTopInput(
                      "Rozst. Poz (Y)",
                      _spacingYController,
                      (v) => spacingY = v,
                    ),
                    const SizedBox(width: 15),
                    ElevatedButton.icon(
                      onPressed: _calculateProfiles,
                      icon: const Icon(Icons.calculate),
                      label: const Text("Licz"),
                    ),
                    // --- KLUCZOWY FRAGMENT WYŚWIETLAJĄCY WYNIK ---
                    if (calculationResult.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black45,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: Colors.greenAccent.withOpacity(0.5),
                            ),
                          ),
                          child: Text(
                            calculationResult,
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // OBSZAR RYSOWANIA
            Expanded(
              child: GestureDetector(
                onTapDown: (_) => FocusScope.of(context).unfocus(),
                onTapUp: (d) => _handleTap(d.localPosition),
                onPanStart: (d) {
                  if (isPanMode) return;
                  setState(() {
                    profilePreviewLines = [];
                    calculationResult = "";
                  });
                  Offset touchWorld = _toWorld(d.localPosition);
                  if (isMoveMode && selectedLineIndex != null) {
                    _pushState();
                    return;
                  }
                  if (selectedLineIndex != null) return;
                  if (pendingStartPoint != null) {
                    setState(() {
                      final start = pendingStartPoint!;
                      currentLine = Line(start, start);
                      _drawingStartPoint = start;
                      pendingStartPoint = null;
                    });
                  } else {
                    Offset start = _findSnapPoint(touchWorld) ?? touchWorld;
                    setState(() {
                      currentLine = Line(start, start);
                      _drawingStartPoint = start;
                    });
                  }
                },
                onPanUpdate: (d) {
                  if (isPanMode) {
                    setState(() {
                      cameraOffset -= d.delta / pixelsPerMeter;
                    });
                    return;
                  }

                  Offset touchWorld = _toWorld(d.localPosition);

                  if (isMoveMode && selectedLineIndex != null) {
                    setState(() {
                      Line line = lines[selectedLineIndex!];
                      Offset delta = d.delta / pixelsPerMeter;
                      Offset newStart = line.start + delta;
                      Offset newEnd = line.end + delta;
                      Offset lineVec = line.end - line.start;

                      Offset? snappedStart = _findSnapPoint(
                        newStart,
                        excludeIndex: selectedLineIndex,
                      );
                      Offset? snappedEnd = _findSnapPoint(
                        newEnd,
                        excludeIndex: selectedLineIndex,
                      );

                      if (snappedStart != null) {
                        line.start = snappedStart;
                        line.end = snappedStart + lineVec;
                      } else if (snappedEnd != null) {
                        line.end = snappedEnd;
                        line.start = snappedEnd - lineVec;
                      } else {
                        line.start = newStart;
                        line.end = newEnd;
                      }
                      closedPolygons = _computeClosedAreas();
                    });
                  } else if (currentLine != null &&
                      _drawingStartPoint != null) {
                    setState(() {
                      final Offset fixedStart = _drawingStartPoint!;

                      double dx = (touchWorld.dx - fixedStart.dx).abs();
                      double dy = (touchWorld.dy - fixedStart.dy).abs();
                      bool horizontal = dx > dy;

                      Offset endPoint;
                      if (horizontal) {
                        double? xSnap = _snapFromTable(
                          touchWorld.dx,
                          _buildXTable(),
                        );
                        endPoint = Offset(
                          xSnap ?? touchWorld.dx,
                          fixedStart.dy,
                        );
                      } else {
                        double? ySnap = _snapFromTable(
                          touchWorld.dy,
                          _buildYTable(),
                        );
                        endPoint = Offset(
                          fixedStart.dx,
                          ySnap ?? touchWorld.dy,
                        );
                      }

                      Offset? pointSnap = _findSnapPoint(endPoint);
                      currentLine!.end = pointSnap ?? endPoint;
                    });
                  }
                },
                onPanEnd: (_) {
                  if (currentLine != null &&
                      (currentLine!.start - currentLine!.end).distance > 0.1) {
                    _addLine(currentLine!);
                  }
                  setState(() {
                    currentLine = null;
                    _drawingStartPoint = null;
                  });
                },
                child: Container(
                  color: const Color(0xFF121212),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: CadPainter(
                      lines,
                      currentLine,
                      pixelsPerMeter,
                      metersPerGrid,
                      selectedLineIndex,
                      cameraOffset,
                      closedPolygons,
                      profilePreviewLines,
                      profileLongitudinalLines,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        color: Colors.black87,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text("Zoom: "),
                Expanded(
                  child: Slider(
                    value: pixelsPerMeter,
                    min: 10,
                    max: 200,
                    onChanged: (double newZoom) {
                      setState(() {
                        Size screenSize = MediaQuery.of(context).size;
                        Offset screenCenter = Offset(
                          screenSize.width / 2,
                          (screenSize.height - 200) / 2,
                        );
                        Offset worldPointAtCenter =
                            screenCenter / pixelsPerMeter + cameraOffset;

                        pixelsPerMeter = newZoom;
                        cameraOffset =
                            worldPointAtCenter - (screenCenter / newZoom);

                        _updateDynamicGrid();
                      });
                    },
                  ),
                ),
                const Text("  1 kratka = "),
                Text(
                  "${metersPerGrid.toStringAsFixed(metersPerGrid < 1 ? 2 : 1)} m",
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.amber,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Text(
                  isPanMode
                      ? "🔍 Tryb przesuwania widoku"
                      : (isMoveMode
                            ? "↔ Tryb przesuwania linii"
                            : "📐 Tryb rysowania/edycji"),
                  style: TextStyle(
                    fontSize: 10,
                    color: isPanMode ? Colors.orange : Colors.blue,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSideInput(
    String label,
    TextEditingController controller,
    Function(double) onUpdate,
  ) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(), // Poprawne umiejscowienie border
      ),
      onChanged: (v) {
        final val = double.tryParse(v.replaceFirst(',', '.'));
        if (val != null) setState(() => onUpdate(val));
      },
    );
  }

  Widget _buildTopInput(
    String label,
    TextEditingController controller,
    Function(double) onUpdate,
  ) {
    return SizedBox(
      width: 120,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          labelStyle: const TextStyle(fontSize: 11),
          border: const OutlineInputBorder(),
          errorText:
              double.tryParse(controller.text.replaceFirst(',', '.')) == null
              ? ""
              : null,
        ),
        style: const TextStyle(fontSize: 13),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (v) {
          setState(() {
            final val = double.tryParse(v.replaceFirst(',', '.'));
            if (val != null) {
              onUpdate(val);
              _isInputValid = true;
            } else {
              _isInputValid = false;
            }
          });
        },
      ),
    );
  }
}

class CadPainter extends CustomPainter {
  final List<Line> lines;
  final Line? currentLine;
  final double zoom;
  final double gridMeters;
  final int? selectedIndex;
  final Offset cameraOffset;
  final List<List<Offset>> closedPolygons;
  final List<Line> profilePreviewLines;
  final List<Line> profileLongitudinalLines;

  CadPainter(
    this.lines,
    this.currentLine,
    this.zoom,
    this.gridMeters,
    this.selectedIndex,
    this.cameraOffset,
    this.closedPolygons,
    this.profilePreviewLines,
    this.profileLongitudinalLines,
  );

  @override
  void paint(Canvas canvas, Size size) {
    _drawGrid(canvas, size);
    _drawClosedAreas(canvas, size);

    final profilePaint = Paint()
      ..color = Colors.brown
      ..strokeWidth = 1.5;

    for (var line in profilePreviewLines) {
      Offset p1 = _toScreen(line.start);
      Offset p2 = _toScreen(line.end);
      canvas.drawLine(p1, p2, profilePaint);
    }

    final longitudinalPaint = Paint()
      ..color = Colors.grey
      ..strokeWidth = 1.5;

    for (var line in profileLongitudinalLines) {
      Offset p1 = _toScreen(line.start);
      Offset p2 = _toScreen(line.end);
      canvas.drawLine(p1, p2, longitudinalPaint);
    }

    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0;
    final selectedPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 3.0;
    final activePaint = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 2.0;

    for (int i = 0; i < lines.length; i++) {
      _drawLine(canvas, lines[i], i == selectedIndex ? selectedPaint : paint);
    }
    if (currentLine != null) {
      _drawLine(canvas, currentLine!, activePaint);
    }
  }

  void _drawClosedAreas(Canvas canvas, Size size) {
    final greenPaint = Paint()
      ..color = Colors.green.withOpacity(0.4)
      ..style = PaintingStyle.fill;
    for (var poly in closedPolygons) {
      if (poly.length < 3) continue;
      Path path = Path();
      Offset first = _toScreen(poly[0]);
      path.moveTo(first.dx, first.dy);
      for (int i = 1; i < poly.length; i++) {
        Offset p = _toScreen(poly[i]);
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, greenPaint);
    }
  }

  void _drawLine(Canvas canvas, Line line, Paint paint) {
    Offset p1 = _toScreen(line.start);
    Offset p2 = _toScreen(line.end);
    canvas.drawLine(p1, p2, paint);

    double meters = (line.start - line.end).distance;
    TextPainter(
        text: TextSpan(
          text: " ${meters.toStringAsFixed(2)}m ",
          style: TextStyle(
            backgroundColor: Colors.black,
            color: paint.color,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )
      ..layout()
      ..paint(canvas, (p1 + p2) / 2);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white10;
    Rect visibleWorld = Rect.fromLTWH(
      cameraOffset.dx,
      cameraOffset.dy,
      size.width / zoom,
      size.height / zoom,
    );
    double startX = (visibleWorld.left / gridMeters).floor() * gridMeters;
    double startY = (visibleWorld.top / gridMeters).floor() * gridMeters;
    double endX = visibleWorld.right;
    double endY = visibleWorld.bottom;

    for (double x = startX; x <= endX; x += gridMeters) {
      Offset start = _toScreen(Offset(x, visibleWorld.top));
      Offset end = _toScreen(Offset(x, visibleWorld.bottom));
      canvas.drawLine(start, end, p);
    }
    for (double y = startY; y <= endY; y += gridMeters) {
      Offset start = _toScreen(Offset(visibleWorld.left, y));
      Offset end = _toScreen(Offset(visibleWorld.right, y));
      canvas.drawLine(start, end, p);
    }
  }

  Offset _toScreen(Offset world) => (world - cameraOffset) * zoom;

  @override
  bool shouldRepaint(covariant CadPainter old) =>
      old.lines != lines ||
      old.currentLine != currentLine ||
      old.zoom != zoom ||
      old.gridMeters != gridMeters ||
      old.selectedIndex != selectedIndex ||
      old.cameraOffset != cameraOffset ||
      old.closedPolygons != closedPolygons ||
      old.profilePreviewLines != profilePreviewLines ||
      old.profileLongitudinalLines != profileLongitudinalLines;
}
