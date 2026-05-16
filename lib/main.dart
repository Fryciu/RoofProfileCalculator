import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

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

class UndoIntent extends Intent {}

class RedoIntent extends Intent {}

class DeleteIntent extends Intent {}

class CadCanvas extends StatefulWidget {
  const CadCanvas({super.key});
  @override
  State<CadCanvas> createState() => _CadCanvasState();
}

class _CadCanvasState extends State<CadCanvas> {
  List<Line> lines = [];
  bool _isInputValid = true;
  bool isAxisSwapped = false;
  late FocusNode _keyboardFocusNode;

  List<List<Line>> _undoStack = [];
  List<List<Line>> _redoStack = [];
  List<Line> profilePreviewLines = [];
  List<Line> profileNosneLines = [];
  List<Line> profileGlowneLines = [];
  List<Offset> hangerPositions = [];
  List<Offset> crossConnectorPositions = [];
  List<Offset> connectorPositions = [];
  bool _showSidePanel = true;

  Map<String, bool> layerVisibility = {
    'nosne': true,
    'glowne': true,
    'obszary': true,
    'linie': true,
    'siatka': true,
    'wieszaki': true,
    'lacznikiKrzyz': true,
    'laczniki': true,
  };

  double marginX = 0.2;
  double marginY = 0.2;
  double spacingX = 0.6;
  double spacingY = 0.6;
  double hangerMargin = 0.3;
  double hangerSpacing = 0.7;
  double plugWallMargin = 0.1;
  double plugSpacing = 0.4;
  double screwsPerMeterSq = 20.0;
  double connectorSpacing = 3.0;
  double clipsPerConnector = 4.0;

  late final TextEditingController _marginXController;
  late final TextEditingController _marginYController;
  late final TextEditingController _spacingXController;
  late final TextEditingController _spacingYController;
  late final TextEditingController _hangerMarginController;
  late final TextEditingController _hangerSpacingController;
  late final TextEditingController _plugWallMarginController;
  late final TextEditingController _plugSpacingController;
  late final TextEditingController _screwsPerMeterSqController;
  late final TextEditingController _connectorSpacingController;
  late final TextEditingController _clipsPerConnectorController;

  Future<void> _saveValue(String key, double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(key, value);
  }

  Future<void> _loadDefaultValues() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      marginX = prefs.getDouble('marginX') ?? 0.2;
      marginY = prefs.getDouble('marginY') ?? 0.2;
      spacingX = prefs.getDouble('spacingX') ?? 0.6;
      spacingY = prefs.getDouble('spacingY') ?? 0.6;
      hangerSpacing = prefs.getDouble('hangerSpacing') ?? 0.7;
      hangerMargin = prefs.getDouble('hangerMargin') ?? 0.3;
      plugSpacing = prefs.getDouble('plugSpacing') ?? 0.4;
      plugWallMargin = prefs.getDouble('plugWallMargin') ?? 0.1;
      screwsPerMeterSq = prefs.getDouble('screwsPerMeterSq') ?? 20.0;
      connectorSpacing = prefs.getDouble('connectorSpacing') ?? 3.0;
      clipsPerConnector = prefs.getDouble('clipsPerConnector') ?? 4.0;

      _connectorSpacingController.text = connectorSpacing.toString();
      _clipsPerConnectorController.text = clipsPerConnector.toString();
      _marginXController.text = marginX.toString();
      _marginYController.text = marginY.toString();
      _spacingXController.text = spacingX.toString();
      _spacingYController.text = spacingY.toString();
      _hangerSpacingController.text = hangerSpacing.toString();
      _hangerMarginController.text = hangerMargin.toString();
      _plugSpacingController.text = plugSpacing.toString();
      _plugWallMarginController.text = plugWallMargin.toString();
      _screwsPerMeterSqController.text = screwsPerMeterSq.toString();
    });
  }

  @override
  void initState() {
    super.initState();
    _keyboardFocusNode = FocusNode();
    _keyboardFocusNode.requestFocus();
    _lengthEditController = TextEditingController();
    _lengthEditFocusNode = FocusNode();
    _connectorSpacingController = TextEditingController();
    _clipsPerConnectorController = TextEditingController();
    _marginXController = TextEditingController();
    _marginYController = TextEditingController();
    _spacingXController = TextEditingController();
    _spacingYController = TextEditingController();
    _hangerSpacingController = TextEditingController();
    _hangerMarginController = TextEditingController();
    _plugSpacingController = TextEditingController();
    _plugWallMarginController = TextEditingController();
    _screwsPerMeterSqController = TextEditingController();
    _loadDefaultValues();
  }

  String calculationResult = "";
  int _reportCount = 0;
  double _reportLength = 0;
  int _reportConnectors = 0;
  int _reportHangers = 0;
  int _reportPlugs = 0;
  int _reportScrews = 0;
  double _reportArea = 0;
  int _reportClips = 0;
  int _reportCrossConnectors = 0;
  bool _hasReport = false;
  Line? currentLine;
  Offset? _drawingStartPoint;
  Set<int> selectedIndices = {};
  bool isMultiSelect = false;
  int? _lengthEditIndex;
  Offset? _lengthEditScreenPos;
  late final TextEditingController _lengthEditController;
  late final FocusNode _lengthEditFocusNode;
  Offset? _selectionRectStart;
  Offset? _selectionRectEnd;

  double pixelsPerMeter = 50.0;
  double metersPerGrid = 1.0;
  double snapThresholdMeters = 0.2;

  Offset cameraOffset = Offset.zero;
  bool isPanMode = false;
  Offset? pendingStartPoint;
  Offset? _lastTapUpPos;
  DateTime? _lastTapUpTime;

  late final TextEditingController _gridController = TextEditingController();

  List<List<Offset>> closedPolygons = [];

  void _pushState() {
    _undoStack.add(lines.map((l) => l.copy()).toList());
    _redoStack.clear();
    _computeClosedAreas();
  }

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

  int _countIntersections(List<Line> previewLines, List<Offset> outPositions) {
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
        if (h.start.dy >= minV_Y &&
            h.start.dy <= maxV_Y &&
            v.start.dx >= minH_X &&
            v.start.dx <= maxH_X) {
          count++;
          outPositions.add(Offset(v.start.dx, h.start.dy));
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

  List<Line> _clipHorizontalLine(double y, List<Offset> poly) {
    List<double> intersections = [];
    for (int i = 0; i < poly.length; i++) {
      Offset p1 = poly[i];
      Offset p2 = poly[(i + 1) % poly.length];
      if ((p1.dy <= y && p2.dy > y) || (p2.dy <= y && p1.dy > y)) {
        double x = p1.dx + (y - p1.dy) * (p2.dx - p1.dx) / (p2.dy - p1.dy);
        intersections.add(x);
      }
    }
    intersections.sort();
    List<Line> result = [];
    for (int i = 0; i < intersections.length - 1; i += 2) {
      if ((intersections[i + 1] - intersections[i]).abs() > 0.001) {
        result.add(
          Line(Offset(intersections[i], y), Offset(intersections[i + 1], y)),
        );
      }
    }
    return result;
  }

  List<Line> _clipVerticalLine(double x, List<Offset> poly) {
    List<double> intersections = [];
    for (int i = 0; i < poly.length; i++) {
      Offset p1 = poly[i];
      Offset p2 = poly[(i + 1) % poly.length];
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

  Offset _normalizePt(Offset p) => Offset(
    (p.dx * 100).roundToDouble() / 100,
    (p.dy * 100).roundToDouble() / 100,
  );

  void _addLine(Line line) {
    _undoStack.add(lines.map((l) => l.copy()).toList());
    _redoStack.clear();
    setState(() {
      lines.add(Line(_normalizePt(line.start), _normalizePt(line.end)));
      pendingStartPoint = _normalizePt(line.end);
    });
    setState(() {
      closedPolygons = _computeClosedAreas();
    });
  }

  void _deleteSelected() {
    if (lines.isEmpty) return;
    _pushState();
    setState(() {
      if (selectedIndices.isNotEmpty) {
        var sorted = selectedIndices.toList()..sort((a, b) => b.compareTo(a));
        for (var i in sorted) {
          if (i < lines.length) lines.removeAt(i);
        }
        selectedIndices.clear();
      } else {
        lines.clear();
      }
      pendingStartPoint = null;
      currentLine = null;
      _cancelLengthEdit();
    });
    setState(() {
      closedPolygons = _computeClosedAreas();
      profilePreviewLines = [];
      profileNosneLines = [];
      profileGlowneLines = [];
      hangerPositions = [];
      crossConnectorPositions = [];
      connectorPositions = [];
      calculationResult = "";
      _hasReport = false;
    });
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      _redoStack.add(lines.map((l) => l.copy()).toList());
      lines = _undoStack.removeLast();
      selectedIndices.clear();
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
      selectedIndices.clear();
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
        profileNosneLines = [];
        profileGlowneLines = [];
        _hasReport = false;
      });
      return;
    }

    if (closedPolygons.isEmpty) {
      setState(() {
        calculationResult = "Brak zamkniętych obszarów!";
        _hasReport = false;
      });
      return;
    }

    double totalLength = 0;
    int totalCount = 0;
    int totalHangers = 0;
    int totalPlugs = 0;
    int connectors = 0;

    List<Line> newPreviewLines = [];
    List<Line> newNosneLines = [];
    List<Line> newGlowneLines = [];
    List<Offset> newHangerPositions = [];
    List<Offset> newConnectorPositions = [];

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

    List<double> _getHangerOffsets(Line line) {
      double len = (line.start - line.end).distance;
      double endMarginLimit = len - hangerMargin;
      if (len < (hangerMargin * 2)) return [];
      List<double> offsets = [hangerMargin];
      double currentPos = hangerMargin;
      while (currentPos + hangerSpacing <= endMarginLimit + 0.001) {
        currentPos += hangerSpacing;
        offsets.add(currentPos);
      }
      if ((endMarginLimit - currentPos).abs() > 0.05) {
        offsets.add(endMarginLimit);
      }
      return offsets;
    }

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

    for (var line in lines) {
      double len = (line.start - line.end).distance;
      if (len >= (plugWallMargin * 2)) {
        totalPlugs++;
        double currentPos = plugWallMargin;
        while (currentPos + plugSpacing <= len - plugWallMargin + 0.001) {
          totalPlugs++;
          currentPos += plugSpacing;
        }
        if ((len - plugWallMargin - currentPos).abs() > 0.001) totalPlugs++;
      } else if (len > 0.02) {
        totalPlugs++;
      }
    }

    for (var poly in closedPolygons) {
      double area = 0;
      for (int i = 0; i < poly.length; i++) {
        area +=
            (poly[i].dx * poly[(i + 1) % poly.length].dy -
            poly[(i + 1) % poly.length].dx * poly[i].dy);
      }
      if (area <= 0) continue;

      double xMargin = isAxisSwapped ? marginY : marginX;
      double xSpacing = isAxisSwapped ? spacingY : spacingX;
      double yMargin = isAxisSwapped ? marginX : marginY;
      double ySpacing = isAxisSwapped ? spacingX : spacingY;

      List<double> xPositions = generatePositions(
        poly,
        true,
        xMargin,
        xSpacing,
      );
      List<double> yPositions = generatePositions(
        poly,
        false,
        yMargin,
        ySpacing,
      );

      List<List<Line>> verticalCols = [];
      for (double x in xPositions) {
        List<Line> segments = _clipVerticalLine(x, poly);
        verticalCols.add(segments);
        for (var seg in segments) {
          newPreviewLines.add(seg);
          if (isAxisSwapped) {
            newNosneLines.add(seg);
          } else {
            newGlowneLines.add(seg);
          }
          totalCount++;
          double len = (seg.start - seg.end).distance;
          totalLength += len;
          if (isAxisSwapped) {
            List<double> hOffsets = _getHangerOffsets(seg);
            for (var d in hOffsets) {
              Offset dir = (seg.end - seg.start) / len;
              newHangerPositions.add(seg.start + dir * d);
            }
            totalHangers += hOffsets.length;
            totalPlugs += hOffsets.length;
            int n = ((len - 0.0001) / connectorSpacing).floor();
            connectors += n;
            Offset dir = (seg.end - seg.start) / len;
            for (int i = 1; i <= n; i++) {
              newConnectorPositions.add(
                seg.start + dir * (i * connectorSpacing),
              );
            }
          } else {
            int n = ((len - 0.0001) / connectorSpacing).floor();
            connectors += n;
            Offset dir = (seg.end - seg.start) / len;
            for (int i = 1; i <= n; i++) {
              newConnectorPositions.add(
                seg.start + dir * (i * connectorSpacing),
              );
            }
          }
        }
      }

      List<List<Line>> horizontalRows = [];
      for (double y in yPositions) {
        List<Line> segments = _clipHorizontalLine(y, poly);
        horizontalRows.add(segments);
        for (var seg in segments) {
          double len = (seg.start - seg.end).distance;
          newPreviewLines.add(seg);
          if (!isAxisSwapped) {
            newNosneLines.add(seg);
          } else {
            newGlowneLines.add(seg);
          }
          totalCount++;
          totalLength += len;
          if (!isAxisSwapped) {
            List<double> hOffsets = _getHangerOffsets(seg);
            for (var d in hOffsets) {
              Offset dir = (seg.end - seg.start) / len;
              newHangerPositions.add(seg.start + dir * d);
            }
            totalHangers += hOffsets.length;
            totalPlugs += hOffsets.length;
            int n = ((len - 0.0001) / connectorSpacing).floor();
            connectors += n;
            Offset dir = (seg.end - seg.start) / len;
            for (int i = 1; i <= n; i++) {
              newConnectorPositions.add(
                seg.start + dir * (i * connectorSpacing),
              );
            }
          } else {
            int n = ((len - 0.0001) / connectorSpacing).floor();
            connectors += n;
            Offset dir = (seg.end - seg.start) / len;
            for (int i = 1; i <= n; i++) {
              newConnectorPositions.add(
                seg.start + dir * (i * connectorSpacing),
              );
            }
          }
        }
      }
    }

    double totalScrews = 0;
    double totalArea = 0;
    for (var poly in closedPolygons) {
      double area = 0;
      for (int i = 0; i < poly.length; i++) {
        area +=
            (poly[i].dx * poly[(i + 1) % poly.length].dy -
            poly[(i + 1) % poly.length].dx * poly[i].dy);
      }
      area = area.abs() / 2.0;
      if (area <= 0) continue;
      totalArea += area;
      totalScrews += area * screwsPerMeterSq;
    }
    totalArea = totalArea / 2.0;
    totalScrews = totalScrews / 2.0;

    int clips = (connectors * clipsPerConnector).round();
    List<Offset> newCrossPositions = [];
    int crossConnectors = _countIntersections(
      newPreviewLines,
      newCrossPositions,
    );
    setState(() {
      profilePreviewLines = newPreviewLines;
      profileNosneLines = newNosneLines;
      profileGlowneLines = newGlowneLines;
      hangerPositions = newHangerPositions;
      crossConnectorPositions = newCrossPositions;
      connectorPositions = newConnectorPositions;
      calculationResult = "Statystyki gotowe";
      _reportCount = totalCount;
      _reportLength = totalLength;
      _reportConnectors = connectors;
      _reportHangers = totalHangers;
      _reportPlugs = totalPlugs;
      _reportArea = totalArea;
      _reportClips = clips;
      _reportCrossConnectors = crossConnectors;
      _reportScrews = (totalArea * screwsPerMeterSq).ceil();
      _hasReport = true;
    });
  }

  Widget _resRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Flexible(child: Text(label)),
          const SizedBox(width: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(fontWeight: FontWeight.bold, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label, String key) {
    return GestureDetector(
      onTap: () => setState(() {
        layerVisibility = Map.from(layerVisibility)
          ..[key] = !(layerVisibility[key] ?? true);
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: (layerVisibility[key] ?? true)
                    ? color
                    : Colors.grey[800],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: (layerVisibility[key] ?? true)
                    ? Colors.white
                    : Colors.grey[600],
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _centerViewOnLines() {
    if (lines.isEmpty) return;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
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
    if (fraction < 1.5)
      niceFraction = 1.0;
    else if (fraction < 3.5)
      niceFraction = 2.0;
    else if (fraction < 7.5)
      niceFraction = 5.0;
    else
      niceFraction = 10.0;

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
      if (dist < (12 / pixelsPerMeter)) foundIndex = i;
    }
    if (isMultiSelect) {
      setState(() {
        if (foundIndex != null) {
          if (selectedIndices.contains(foundIndex)) {
            selectedIndices.remove(foundIndex);
          } else {
            selectedIndices.add(foundIndex);
          }
        }
        pendingStartPoint = null;
      });
      return;
    }
    setState(() {
      if (foundIndex != null) {
        selectedIndices = {foundIndex};
        pendingStartPoint = null;
        _startLengthEdit(foundIndex, touchWorld);
      } else {
        selectedIndices.clear();
        pendingStartPoint = touchWorld;
        _cancelLengthEdit();
      }
    });
  }

  void _handleDoubleTap(Offset _) {
    if (_lengthEditIndex != null) {
      _lengthEditFocusNode.requestFocus();
      return;
    }
  }

  void _startLengthEdit(int index, Offset worldPos) {
    Offset midWorld = (lines[index].start + lines[index].end) / 2;
    Offset screenPos = (midWorld - cameraOffset) * pixelsPerMeter;
    _lengthEditScreenPos = screenPos;
    _lengthEditIndex = index;
    double len = (lines[index].start - lines[index].end).distance;
    _lengthEditController.text = len.toStringAsFixed(2);
  }

  void _cancelLengthEdit() {
    _lengthEditIndex = null;
    _lengthEditScreenPos = null;
  }

  void _confirmLengthEdit() {
    if (_lengthEditIndex == null) return;
    double? val = double.tryParse(_lengthEditController.text);
    if (val != null && val > 0) {
      _pushState();
      setState(() {
        profilePreviewLines = [];
        profileNosneLines = [];
        profileGlowneLines = [];
        calculationResult = "";
        _hasReport = false;
        Line line = lines[_lengthEditIndex!];
        Offset dir = line.end - line.start;
        if (dir.distance <= 0) return;
        bool isHorizontal = dir.dx.abs() > dir.dy.abs();
        Offset anchor = isHorizontal
            ? (line.start.dx < line.end.dx ? line.start : line.end)
            : (line.start.dy < line.end.dy ? line.start : line.end);
        Offset newEnd = isHorizontal
            ? Offset(anchor.dx + val, anchor.dy)
            : Offset(anchor.dx, anchor.dy + val);
        line.start = _normalizePt(anchor);
        line.end = _normalizePt(newEnd);
        closedPolygons = _computeClosedAreas();
        _cancelLengthEdit();
      });
    } else {
      _cancelLengthEdit();
    }
  }

  void _globalAutoMerge() {
    if (lines.isEmpty) return;
    _pushState();
    setState(() {
      const double snapThreshold = 0.15;
      const double joinThreshold = 0.05;
      List<Line> verticals = [];
      List<Line> horizontals = [];
      List<Line> others = [];
      for (var line in lines) {
        double dx = (line.start.dx - line.end.dx).abs();
        double dy = (line.start.dy - line.end.dy).abs();
        if (dx < 0.1) {
          double avgX = (line.start.dx + line.end.dx) / 2;
          line.start = Offset(avgX, line.start.dy);
          line.end = Offset(avgX, line.end.dy);
          verticals.add(line);
        } else if (dy < 0.1) {
          double avgY = (line.start.dy + line.end.dy) / 2;
          line.start = Offset(line.start.dx, avgY);
          line.end = Offset(line.end.dx, avgY);
          horizontals.add(line);
        } else {
          others.add(line);
        }
      }
      List<Line> mergeSegments(List<Line> segmentList, bool isVertical) {
        if (segmentList.isEmpty) return [];
        List<Line> merged = [];
        while (segmentList.isNotEmpty) {
          Line base = segmentList.removeAt(0);
          double baseCoord = isVertical ? base.start.dx : base.start.dy;
          List<Line> colinear = [base];
          segmentList.removeWhere((l) {
            double coord = isVertical ? l.start.dx : l.start.dy;
            if ((coord - baseCoord).abs() < snapThreshold) {
              colinear.add(l);
              return true;
            }
            return false;
          });
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

      lines = [
        ...others,
        ...mergeSegments(verticals, true),
        ...mergeSegments(horizontals, false),
      ];
      selectedIndices.clear();
      closedPolygons = _computeClosedAreas();
      calculationResult = "Automatycznie zsumowano ściany.";
      _hasReport = false;
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
    _lengthEditController.dispose();
    _lengthEditFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CAD: Profile i Skala'),
        actions: [
          IconButton(
            icon: const Icon(Icons.link, color: Colors.greenAccent),
            tooltip: "Zescal ściany",
            onPressed: _globalAutoMerge,
          ),
          IconButton(
            tooltip: "Cofnij (Ctrl+Z)",
            icon: const Icon(Icons.undo),
            onPressed: _undo,
          ),
          IconButton(
            tooltip: "Ponów (Ctrl+Y)",
            icon: const Icon(Icons.redo),
            onPressed: _redo,
          ),
          IconButton(
            tooltip: "Usuń (Delete)",
            icon: const Icon(Icons.delete),
            onPressed: _deleteSelected,
          ),
          IconButton(
            tooltip: isPanMode ? "Tryb rysowania" : "Tryb przesuwania widoku",
            icon: Icon(isPanMode ? Icons.pan_tool : Icons.pan_tool_outlined),
            onPressed: () => setState(() => isPanMode = !isPanMode),
          ),
          IconButton(
            tooltip: "Tryb zaznaczania",
            icon: Icon(
              Icons.touch_app,
              color: isMultiSelect ? Colors.purpleAccent : null,
            ),
            onPressed: () => setState(() {
              isMultiSelect = !isMultiSelect;
              if (!isMultiSelect) selectedIndices.clear();
            }),
          ),
          IconButton(
            tooltip: "Wyśrodkuj widok",
            icon: const Icon(Icons.center_focus_strong),
            onPressed: _centerViewOnLines,
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
              Text(
                isAxisSwapped
                    ? "Profile główne (pionowe)"
                    : "Profile nośne (pionowe)",
                style: const TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                isAxisSwapped ? "Margines Y (m)" : "Margines X (m)",
                isAxisSwapped ? _marginYController : _marginXController,
                isAxisSwapped ? (v) => marginY = v : (v) => marginX = v,
                isAxisSwapped ? 'marginY' : 'marginX',
              ),
              _buildSideInput(
                isAxisSwapped ? "Rozstaw Y (m)" : "Rozstaw X (m)",
                isAxisSwapped ? _spacingYController : _spacingXController,
                isAxisSwapped ? (v) => spacingY = v : (v) => spacingX = v,
                isAxisSwapped ? 'spacingY' : 'spacingX',
              ),
              const Divider(),
              Text(
                isAxisSwapped
                    ? "Profile nośne (poziome)"
                    : "Profile główne (poziome)",
                style: const TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                isAxisSwapped ? "Margines X (m)" : "Margines Y (m)",
                isAxisSwapped ? _marginXController : _marginYController,
                isAxisSwapped ? (v) => marginX = v : (v) => marginY = v,
                isAxisSwapped ? 'marginX' : 'marginY',
              ),
              _buildSideInput(
                isAxisSwapped ? "Rozstaw X (m)" : "Rozstaw Y (m)",
                isAxisSwapped ? _spacingXController : _spacingYController,
                isAxisSwapped ? (v) => spacingX = v : (v) => spacingY = v,
                isAxisSwapped ? 'spacingX' : 'spacingY',
              ),
              const Divider(),
              const Text(
                "Wieszaki",
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                "Margines wieszaka (m)",
                _hangerMarginController,
                (v) => hangerMargin = v,
                'hangerMargin',
              ),
              _buildSideInput(
                "Rozstaw wieszaków (m)",
                _hangerSpacingController,
                (v) => hangerSpacing = v,
                'hangerSpacing',
              ),
              const Divider(),
              const Text(
                "Kołki montażowe",
                style: TextStyle(
                  color: Colors.pinkAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                "Kołek od ściany (m)",
                _plugWallMarginController,
                (v) => plugWallMargin = v,
                'plugWallMargin',
              ),
              _buildSideInput(
                "Max rozstaw kołków (m)",
                _plugSpacingController,
                (v) => plugSpacing = v,
                'plugSpacing',
              ),
              const Divider(),
              const Text(
                "Płyty i wkręty",
                style: TextStyle(
                  color: Colors.yellowAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                "Wkręty na m²",
                _screwsPerMeterSqController,
                (v) => screwsPerMeterSq = v,
                'screwsPerMeterSq',
              ),
              const Divider(),
              const Text(
                "Łączniki",
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
              _buildSideInput(
                "Rozstaw łączników (m)",
                _connectorSpacingController,
                (v) => connectorSpacing = v,
                'connectorSpacing',
              ),
              _buildSideInput(
                "Pchełki na łącznik",
                _clipsPerConnectorController,
                (v) => clipsPerConnector = v,
                'clipsPerConnector',
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
            ],
          ),
        ),
      ),
      body: RawKeyboardListener(
        focusNode: _keyboardFocusNode,
        onKey: (RawKeyEvent event) {
          if (event is RawKeyDownEvent) {
            final focus = FocusManager.instance.primaryFocus;
            final isEditingText =
                focus?.context?.widget is EditableText ||
                focus?.context?.findAncestorWidgetOfExactType<TextField>() !=
                    null;
            if (isEditingText) return;
            if (HardwareKeyboard.instance.isControlPressed &&
                event.logicalKey == LogicalKeyboardKey.keyZ) {
              _undo();
              return;
            }
            if (HardwareKeyboard.instance.isControlPressed &&
                event.logicalKey == LogicalKeyboardKey.keyY) {
              _redo();
              return;
            }
            if (event.logicalKey == LogicalKeyboardKey.backspace ||
                event.logicalKey == LogicalKeyboardKey.delete) {
              _deleteSelected();
              return;
            }
            if (HardwareKeyboard.instance.isControlPressed &&
                HardwareKeyboard.instance.isShiftPressed &&
                event.logicalKey == LogicalKeyboardKey.keyX) {
              setState(() {
                isAxisSwapped = !isAxisSwapped;
                profilePreviewLines = [];
                profileNosneLines = [];
                profileGlowneLines = [];
                hangerPositions = [];
                crossConnectorPositions = [];
                connectorPositions = [];
                calculationResult = "";
                _hasReport = false;
              });
              return;
            }
          }
        },
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.blueGrey[900],
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  ElevatedButton.icon(
                    onPressed: _calculateProfiles,
                    icon: const Icon(Icons.calculate),
                    label: const Text("Licz"),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        GestureDetector(
                          onTapDown: (d) {
                            FocusScope.of(
                              context,
                            ).requestFocus(_keyboardFocusNode);
                          },
                          onTapUp: (d) {
                            final now = DateTime.now();
                            final dt = _lastTapUpTime != null
                                ? now.difference(_lastTapUpTime!)
                                : Duration.zero;
                            if (dt < const Duration(milliseconds: 350) &&
                                _lastTapUpPos != null &&
                                (_lastTapUpPos! - d.localPosition).distance <
                                    30) {
                              _handleDoubleTap(d.localPosition);
                            } else {
                              _handleTap(d.localPosition);
                            }
                            _lastTapUpTime = now;
                            _lastTapUpPos = d.localPosition;
                          },
                          onPanStart: (d) {
                            if (isPanMode) return;
                            setState(() {
                              profilePreviewLines = [];
                              profileNosneLines = [];
                              profileGlowneLines = [];
                              hangerPositions = [];
                              crossConnectorPositions = [];
                              connectorPositions = [];
                              calculationResult = "";
                              _hasReport = false;
                            });
                            Offset touchWorld = _toWorld(d.localPosition);
                            if (_lengthEditIndex != null) {
                              _confirmLengthEdit();
                            }
                            if (isMultiSelect) {
                              setState(() {
                                _selectionRectStart = touchWorld;
                                _selectionRectEnd = touchWorld;
                              });
                              return;
                            }
                            if (selectedIndices.isNotEmpty) {
                              _pushState();
                              return;
                            }
                            if (pendingStartPoint != null) {
                              setState(() {
                                final start = pendingStartPoint!;
                                currentLine = Line(start, start);
                                _drawingStartPoint = start;
                                pendingStartPoint = null;
                              });
                            } else {
                              Offset start =
                                  _findSnapPoint(touchWorld) ?? touchWorld;
                              setState(() {
                                currentLine = Line(start, start);
                                _drawingStartPoint = start;
                              });
                            }
                          },
                          onPanUpdate: (d) {
                            if (isPanMode) {
                              setState(
                                () => cameraOffset -= d.delta / pixelsPerMeter,
                              );
                              return;
                            }
                            Offset touchWorld = _toWorld(d.localPosition);
                            if (_selectionRectStart != null && isMultiSelect) {
                              setState(() {
                                _selectionRectEnd = touchWorld;
                              });
                              return;
                            }
                            if (selectedIndices.isNotEmpty) {
                              int idx = selectedIndices.first;
                              setState(() {
                                Line line = lines[idx];
                                Offset delta = d.delta / pixelsPerMeter;
                                Offset newStart = line.start + delta;
                                Offset newEnd = line.end + delta;
                                Offset lineVec = line.end - line.start;

                                Offset? snappedStart = _findSnapPoint(
                                  newStart,
                                  excludeIndex: idx,
                                );
                                Offset? snappedEnd = _findSnapPoint(
                                  newEnd,
                                  excludeIndex: idx,
                                );

                                if (snappedStart != null) {
                                  newStart = snappedStart;
                                  newEnd = newStart + lineVec;
                                } else if (snappedEnd != null) {
                                  newEnd = snappedEnd;
                                  newStart = newEnd - lineVec;
                                }

                                var newLines = List<Line>.from(lines);
                                newLines[idx] = Line(newStart, newEnd);
                                lines = newLines;
                                closedPolygons = _computeClosedAreas();
                              });
                            } else if (currentLine != null &&
                                _drawingStartPoint != null) {
                              setState(() {
                                final Offset fixedStart = _drawingStartPoint!;
                                double dx = (touchWorld.dx - fixedStart.dx)
                                    .abs();
                                double dy = (touchWorld.dy - fixedStart.dy)
                                    .abs();
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

                                double? axisSnap = horizontal
                                    ? _snapFromTable(
                                        endPoint.dx,
                                        _buildXTable(),
                                      )
                                    : _snapFromTable(
                                        endPoint.dy,
                                        _buildYTable(),
                                      );
                                Offset snappedEnd = horizontal
                                    ? Offset(
                                        axisSnap ?? endPoint.dx,
                                        fixedStart.dy,
                                      )
                                    : Offset(
                                        fixedStart.dx,
                                        axisSnap ?? endPoint.dy,
                                      );
                                currentLine = Line(fixedStart, snappedEnd);
                              });
                            }
                          },
                          onPanEnd: (_) {
                            if (_selectionRectStart != null &&
                                _selectionRectEnd != null) {
                              double x1 = _selectionRectStart!.dx;
                              double y1 = _selectionRectStart!.dy;
                              double x2 = _selectionRectEnd!.dx;
                              double y2 = _selectionRectEnd!.dy;
                              double minX = x1 < x2 ? x1 : x2;
                              double maxX = x1 > x2 ? x1 : x2;
                              double minY = y1 < y2 ? y1 : y2;
                              double maxY = y1 > y2 ? y1 : y2;
                              setState(() {
                                for (int i = 0; i < lines.length; i++) {
                                  Offset s = lines[i].start;
                                  Offset e = lines[i].end;
                                  if ((s.dx >= minX &&
                                          s.dx <= maxX &&
                                          s.dy >= minY &&
                                          s.dy <= maxY) ||
                                      (e.dx >= minX &&
                                          e.dx <= maxX &&
                                          e.dy >= minY &&
                                          e.dy <= maxY)) {
                                    selectedIndices.add(i);
                                  }
                                }
                                _selectionRectStart = null;
                                _selectionRectEnd = null;
                              });
                              return;
                            }
                            if (currentLine != null &&
                                (currentLine!.start - currentLine!.end)
                                        .distance >
                                    0.1) {
                              _addLine(currentLine!);
                            }
                            setState(() {
                              currentLine = null;
                              _drawingStartPoint = null;
                            });
                          },
                          child: Container(
                            color: const Color(0xFF121212),
                            child: RepaintBoundary(
                              child: CustomPaint(
                                size: Size.infinite,
                                painter: CadPainter(
                                  lines,
                                  currentLine,
                                  pixelsPerMeter,
                                  metersPerGrid,
                                  selectedIndices,
                                  cameraOffset,
                                  closedPolygons,
                                  profileNosneLines,
                                  profileGlowneLines,
                                  hangerPositions,
                                  crossConnectorPositions,
                                  connectorPositions,
                                  _selectionRectStart,
                                  _selectionRectEnd,
                                  _lengthEditIndex,
                                  layerVisibility,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (_lengthEditIndex != null &&
                            _lengthEditScreenPos != null)
                          Positioned(
                            left: _lengthEditScreenPos!.dx,
                            top: _lengthEditScreenPos!.dy,
                            child: SizedBox(
                              width: 46,
                              height: 18,
                              child: TextField(
                                controller: _lengthEditController,
                                focusNode: _lengthEditFocusNode,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(
                                  color: Colors.yellowAccent,
                                  fontSize: 12,
                                  height: 1.0,
                                ),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                  filled: true,
                                  fillColor: Colors.black,
                                  border: InputBorder.none,
                                  suffixText: 'm',
                                  suffixStyle: TextStyle(
                                    color: Colors.yellowAccent,
                                    fontSize: 12,
                                  ),
                                ),
                                onSubmitted: (_) => _confirmLengthEdit(),
                              ),
                            ),
                          ),
                        Positioned(
                          left: 8,
                          bottom: 8,
                          child: Tooltip(
                            message: "Zamień osie (Ctrl+Shift+X)",
                            preferBelow: false,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  isAxisSwapped = !isAxisSwapped;
                                  profilePreviewLines = [];
                                  profileNosneLines = [];
                                  profileGlowneLines = [];
                                  hangerPositions = [];
                                  crossConnectorPositions = [];
                                  connectorPositions = [];
                                  calculationResult = "";
                                  _hasReport = false;
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: isAxisSwapped
                                      ? Colors.blueAccent.withValues(
                                          alpha: 0.85,
                                        )
                                      : Colors.white24,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: DefaultTextStyle(
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    height: 1,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.arrow_upward,
                                            size: 14,
                                            color: Colors.white,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            isAxisSwapped ? "główny" : "nośny",
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.arrow_forward,
                                            size: 14,
                                            color: Colors.white,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            isAxisSwapped ? "nośny" : "główny",
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () =>
                        setState(() => _showSidePanel = !_showSidePanel),
                    child: Container(
                      color: Colors.blueGrey[800],
                      width: 16,
                      child: Center(
                        child: Icon(
                          _showSidePanel
                              ? Icons.chevron_right
                              : Icons.chevron_left,
                          color: Colors.white54,
                          size: 14,
                        ),
                      ),
                    ),
                  ),
                  if (_showSidePanel)
                    Container(
                      width: 240,
                      color: Colors.blueGrey[900],
                      padding: const EdgeInsets.all(12),
                      child: ListView(
                        children: [
                          const Text(
                            "Legenda",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _legendItem(
                            const Color.fromARGB(255, 94, 5, 5),
                            "Profile nośne",
                            'nosne',
                          ),
                          _legendItem(
                            const Color.fromARGB(255, 202, 18, 58),
                            "Profile główne",
                            'glowne',
                          ),
                          _legendItem(
                            Colors.green.withOpacity(0.5),
                            "Obszary zamknięte",
                            'obszary',
                          ),
                          _legendItem(
                            Colors.white,
                            "Linie użytkownika",
                            'linie',
                          ),
                          _legendItem(Colors.white10, "Siatka", 'siatka'),
                          _legendItem(
                            const Color(0xFF26C6DA),
                            "Wieszaki / Druty",
                            'wieszaki',
                          ),
                          _legendItem(
                            const Color(0xFFFF9800),
                            "Łączniki krzyżowe",
                            'lacznikiKrzyz',
                          ),
                          _legendItem(
                            const Color(0xFFCE93D8),
                            "Łączniki wzdłużne",
                            'laczniki wzdluzne',
                          ),
                          if (_hasReport) ...[
                            const SizedBox(height: 12),
                            const Divider(),
                            Row(
                              children: [
                                const Icon(
                                  Icons.analytics,
                                  color: Colors.blueAccent,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  "Pełne Zestawienie",
                                  style: TextStyle(color: Colors.blueGrey[100]),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            _resRow(
                              "Profile główne/nośne:",
                              "${_reportCount} szt.",
                            ),
                            _resRow(
                              "Długość gł./noś.:",
                              "${_reportLength.toStringAsFixed(2)} m",
                            ),
                            const Divider(),
                            _resRow(
                              "Wieszaki:",
                              "${_reportHangers} szt.",
                              color: Colors.cyanAccent,
                            ),
                            _resRow(
                              "Druty:",
                              "${_reportHangers} szt.",
                              color: const Color.fromARGB(255, 31, 141, 209),
                            ),
                            _resRow(
                              "Kołki montażowe:",
                              "${_reportPlugs} szt.",
                              color: Colors.orangeAccent,
                            ),
                            _resRow(
                              "Łączniki wzdłużne:",
                              "${_reportConnectors} szt.",
                              color: Color(0xFFCE93D8),
                            ),
                            _resRow(
                              "Łączniki krzyżowe:",
                              "${_reportCrossConnectors} szt.",
                              color: Colors.blueGrey,
                            ),
                            const SizedBox(height: 8),
                            _resRow(
                              "Powierzchnia całkowita:",
                              "${_reportArea.toStringAsFixed(2)} m²",
                            ),
                            _resRow(
                              "Wkręty (gwoździe):",
                              "${_reportScrews} szt.",
                              color: Colors.yellowAccent,
                            ),
                            _resRow(
                              "Pchełki:",
                              "${_reportClips} szt.",
                              color: Colors.lightBlueAccent,
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
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
                      : (isMultiSelect
                            ? "☑️ Zaznacz linie"
                            : "↔ Przeciągnij = przesuń | Kliknij linię = edytuj długość"),
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
    Function(double) onChanged,
    String saveKey,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(labelText: label, isDense: true),
        keyboardType: TextInputType.number,
        onChanged: (v) {
          final val = double.tryParse(v.replaceFirst(',', '.'));
          if (val != null) {
            onChanged(val);
            _saveValue(saveKey, val);
            setState(() => _isInputValid = true);
          } else {
            setState(() => _isInputValid = false);
          }
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
  final Set<int> selectedIndices;
  final Offset cameraOffset;
  final List<List<Offset>> closedPolygons;
  final List<Line> profileNosneLines;
  final List<Line> profileGlowneLines;
  final List<Offset> hangerPositions;
  final List<Offset> crossConnectorPositions;
  final List<Offset> connectorPositions;
  final Offset? selectionRectStart;
  final Offset? selectionRectEnd;
  final int? lengthEditIndex;
  final Map<String, bool> layerVisibility;

  CadPainter(
    this.lines,
    this.currentLine,
    this.zoom,
    this.gridMeters,
    this.selectedIndices,
    this.cameraOffset,
    this.closedPolygons,
    this.profileNosneLines,
    this.profileGlowneLines,
    this.hangerPositions,
    this.crossConnectorPositions,
    this.connectorPositions,
    this.selectionRectStart,
    this.selectionRectEnd,
    this.lengthEditIndex,
    this.layerVisibility,
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (layerVisibility['siatka'] == true) _drawGrid(canvas, size);
    if (layerVisibility['obszary'] == true) _drawClosedAreas(canvas, size);

    if (selectionRectStart != null && selectionRectEnd != null) {
      final rectPaint = Paint()
        ..color = Colors.purpleAccent.withOpacity(0.2)
        ..style = PaintingStyle.fill;
      final rectBorder = Paint()
        ..color = Colors.purpleAccent
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      final r = Rect.fromPoints(
        _toScreen(selectionRectStart!),
        _toScreen(selectionRectEnd!),
      );
      canvas.drawRect(r, rectPaint);
      canvas.drawRect(r, rectBorder);
    }

    if (layerVisibility['nosne'] == true) {
      final nosnePaint = Paint()
        ..color = const Color(0xFFE57373)
        ..strokeWidth = 2.5;
      for (var line in profileNosneLines) {
        canvas.drawLine(_toScreen(line.start), _toScreen(line.end), nosnePaint);
      }
    }

    if (layerVisibility['glowne'] == true) {
      final glownePaint = Paint()
        ..color = const Color(0xFF81C784)
        ..strokeWidth = 2.0;
      for (var line in profileGlowneLines) {
        canvas.drawLine(
          _toScreen(line.start),
          _toScreen(line.end),
          glownePaint,
        );
      }
    }

    if (layerVisibility['lacznikiKrzyz'] == true) {
      final crossPaint = Paint()
        ..color = const Color(0xFFFF9800)
        ..style = PaintingStyle.fill;
      for (var pos in crossConnectorPositions) {
        canvas.drawCircle(_toScreen(pos), 4, crossPaint);
      }
    }

    if (layerVisibility['laczniki'] == true) {
      final connPaint = Paint()
        ..color = const Color(0xFFCE93D8)
        ..style = PaintingStyle.fill;
      for (var pos in connectorPositions) {
        canvas.drawCircle(_toScreen(pos), 3, connPaint);
      }
    }

    if (layerVisibility['wieszaki'] == true) {
      final hangerPaint = Paint()
        ..color = const Color(0xFF26C6DA)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      final hangerFill = Paint()
        ..color = const Color(0xFF26C6DA)
        ..style = PaintingStyle.fill;
      for (var pos in hangerPositions) {
        final s = _toScreen(pos);
        canvas.drawCircle(s, 4, hangerFill);
        canvas.drawCircle(s, 4, hangerPaint);
      }
    }

    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.0;
    final selectedPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 3.0;
    final editingPaint = Paint()
      ..color = Colors.yellowAccent
      ..strokeWidth = 4.0;
    final activePaint = Paint()
      ..color = Colors.blueAccent
      ..strokeWidth = 2.0;

    if (layerVisibility['linie'] == true) {
      for (int i = 0; i < lines.length; i++) {
        Paint lp;
        bool skipLabel = false;
        if (i == lengthEditIndex) {
          lp = editingPaint;
          skipLabel = true;
        } else if (selectedIndices.contains(i)) {
          lp = selectedPaint;
        } else {
          lp = paint;
        }
        _drawLine(canvas, lines[i], lp, skipLabel: skipLabel);
      }
    }
    if (currentLine != null) _drawLine(canvas, currentLine!, activePaint);
  }

  void _drawClosedAreas(Canvas canvas, Size size) {
    final greenPaint = Paint()
      ..color = Colors.green.withOpacity(0.4)
      ..style = PaintingStyle.fill;
    for (var poly in closedPolygons) {
      if (poly.length < 3) continue;
      final path = Path()..moveTo(_toScreen(poly[0]).dx, _toScreen(poly[0]).dy);
      for (int i = 1; i < poly.length; i++) {
        final p = _toScreen(poly[i]);
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, greenPaint);
    }
  }

  void _drawLine(
    Canvas canvas,
    Line line,
    Paint paint, {
    bool skipLabel = false,
  }) {
    final p1 = _toScreen(line.start);
    final p2 = _toScreen(line.end);
    canvas.drawLine(p1, p2, paint);
    if (skipLabel) return;
    final meters = (line.start - line.end).distance;
    TextPainter(
        text: TextSpan(
          text: " ${meters.toStringAsFixed(2)} m",
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
    final visibleWorld = Rect.fromLTWH(
      cameraOffset.dx,
      cameraOffset.dy,
      size.width / zoom,
      size.height / zoom,
    );
    final startX = (visibleWorld.left / gridMeters).floor() * gridMeters;
    final startY = (visibleWorld.top / gridMeters).floor() * gridMeters;
    for (double x = startX; x <= visibleWorld.right; x += gridMeters) {
      canvas.drawLine(
        _toScreen(Offset(x, visibleWorld.top)),
        _toScreen(Offset(x, visibleWorld.bottom)),
        p,
      );
    }
    for (double y = startY; y <= visibleWorld.bottom; y += gridMeters) {
      canvas.drawLine(
        _toScreen(Offset(visibleWorld.left, y)),
        _toScreen(Offset(visibleWorld.right, y)),
        p,
      );
    }
  }

  Offset _toScreen(Offset world) => (world - cameraOffset) * zoom;

  @override
  bool shouldRepaint(covariant CadPainter old) =>
      old.lines != lines ||
      old.currentLine != currentLine ||
      old.zoom != zoom ||
      old.gridMeters != gridMeters ||
      old.selectedIndices != selectedIndices ||
      old.cameraOffset != cameraOffset ||
      old.closedPolygons != closedPolygons ||
      old.profileNosneLines != profileNosneLines ||
      old.profileGlowneLines != profileGlowneLines ||
      old.hangerPositions != hangerPositions ||
      old.crossConnectorPositions != crossConnectorPositions ||
      old.connectorPositions != connectorPositions ||
      old.selectionRectStart != selectionRectStart ||
      old.selectionRectEnd != selectionRectEnd ||
      old.lengthEditIndex != lengthEditIndex ||
      old.layerVisibility != layerVisibility;
}
