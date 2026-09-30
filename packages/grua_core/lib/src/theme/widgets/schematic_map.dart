import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/value_objects.dart';
import '../brand.dart';
import '../palette.dart';

/// What to draw on a [SchematicMap].
@immutable
class MapMarker {
  const MapMarker({
    required this.position,
    required this.kind,
    this.heading = 0,
    this.label,
    this.id,
    this.onTap,
    this.arrival = 1,
  });

  /// Makes the marker tappable. A marker with one shows no info window of its
  /// own: the tap is the caller's to answer.
  final VoidCallback? onTap;

  final LatLng position;
  final MapMarkerKind kind;

  /// Keeps a marker the same marker as the list around it changes. Without
  /// it the map matches markers by position in the list, and a truck that
  /// takes the slot "Tú" had is shown with "Tú"'s info window.
  final String? id;

  /// How far through its arrival the marker is, 0 to 1: at 0 it hangs above
  /// its point, at 1 it sits on it. A truck the search has just found drops
  /// in rather than appearing out of nowhere, which is the difference between
  /// a list that grew and a list that was always that long.
  final double arrival;

  /// Degrees clockwise from north. Rotates the truck glyph.
  final double heading;
  final String? label;
}

enum MapMarkerKind {
  pickup,
  dropoff,
  truckIdle,
  truckOnService,
  truckStale,
  user,

  /// The person holding the phone, as a red drop: "you are here".
  me,

  /// The customer as the chofer sees them: a blue pin, so it cannot be
  /// mistaken for the chofer's own red one.
  customer;

  /// Pins stand on their point; everything else is centred on it.
  bool get isPin => switch (this) {
        pickup || dropoff || me || customer => true,
        _ => false,
      };
}

/// One line to draw on a map: a leg of a trip.
@immutable
class MapRoute {
  const MapRoute({
    required this.points,
    this.color = BrandColors.red,
    this.dashed = false,
  });

  final List<LatLng> points;
  final Color color;

  /// Dashed reads as "not yet" or "approximate": the leg after the pickup, or
  /// a straight line standing in for a road route.
  final bool dashed;
}

/// A shaded circle on the ground, e.g. the area a search covers.
@immutable
class MapCircle {
  const MapCircle({
    required this.center,
    required this.radiusMeters,
    this.color = BrandColors.red,
    this.fillOpacity = 0.08,
    this.strokeOpacity = 0.45,
  });

  final LatLng center;
  final double radiusMeters;
  final Color color;

  /// How solid the shading and the edge are. The defaults are the search
  /// area; the radar rings that travel across it pass their own, fading as
  /// they go, and no fill at all.
  final double fillOpacity;
  final double strokeOpacity;

  /// North, south, east and west edges: what a camera must show to frame it.
  List<LatLng> get extremes {
    final dLat = radiusMeters / 111320;
    final dLng = radiusMeters / (111320 * math.cos(center.latitude * math.pi / 180));
    return [
      LatLng(center.latitude + dLat, center.longitude),
      LatLng(center.latitude - dLat, center.longitude),
      LatLng(center.latitude, center.longitude + dLng),
      LatLng(center.latitude, center.longitude - dLng),
    ];
  }
}

/// The centre and zoom that fit [points] into [size] with [padding] around
/// them, in the same Web Mercator terms both maps use. Null when there is
/// nothing to fit.
({LatLng center, double zoom})? cameraFitting(
  List<LatLng> points,
  Size size, {
  double padding = 48,
  double maxZoom = 16,
}) {
  if (points.isEmpty || size.isEmpty) return null;
  if (points.length == 1) return (center: points.first, zoom: maxZoom);

  double x(double lng) => (lng + 180) / 360;
  double y(double lat) {
    final s = math.sin(lat * math.pi / 180).clamp(-0.9999, 0.9999);
    return 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
  }

  final xs = points.map((p) => x(p.longitude)).toList();
  final ys = points.map((p) => y(p.latitude)).toList();
  final minX = xs.reduce(math.min);
  final maxX = xs.reduce(math.max);
  final minY = ys.reduce(math.min);
  final maxY = ys.reduce(math.max);

  final lats = points.map((p) => p.latitude);
  final lngs = points.map((p) => p.longitude);
  final center = LatLng(
    (lats.reduce(math.min) + lats.reduce(math.max)) / 2,
    (lngs.reduce(math.min) + lngs.reduce(math.max)) / 2,
  );

  // World widths (at zoom 0 the world is 256 px) that still fit the box.
  final width = math.max(size.width - padding * 2, 1);
  final height = math.max(size.height - padding * 2, 1);
  final spanX = math.max(maxX - minX, 1e-9);
  final spanY = math.max(maxY - minY, 1e-9);
  final zoom = math.log(math.min(width / spanX, height / spanY) / 256) / math.ln2;

  return (center: center, zoom: zoom.clamp(3, maxZoom).toDouble());
}

/// A drawn stand-in for a real map.
///
/// Google Maps needs a billed API key, which a fresh checkout does not have. A
/// grey rectangle in its place would misrepresent every screen it appears on,
/// so this draws a plausible Dominican street grid — arterials, secondary
/// streets, blocks, a river — at the right scale for the given centre and zoom,
/// and projects markers onto it with the same Web Mercator maths the real map
/// uses. Positions are therefore correct relative to one another, which is what
/// the screens are actually demonstrating.
///
/// It is a development affordance. `GoogleMap` replaces it as soon as
/// `GOOGLE_MAPS_API_KEY` is configured.
class SchematicMap extends StatelessWidget {
  const SchematicMap({
    required this.center,
    this.zoom = 14,
    this.markers = const [],
    this.route = const [],
    this.routes = const [],
    this.circles = const [],
    this.showAttribution = true,
    super.key,
  });

  final List<MapCircle> circles;

  final LatLng center;
  final double zoom;
  final List<MapMarker> markers;

  /// Polyline drawn beneath the markers, e.g. pickup → dropoff.
  final List<LatLng> route;

  /// Further legs, each in its own colour, drawn under [route].
  final List<MapRoute> routes;
  final bool showAttribution;

  /// The tappable marker nearest [local], if one is close enough to mean it.
  MapMarker? _markerAt(Offset local, Size size) {
    final painter = _SchematicMapPainter(
      center: center,
      zoom: zoom,
      markers: markers,
      routes: const [],
      circles: const [],
      textDirection: TextDirection.ltr,
      // This one only projects; nothing it is asked for is coloured.
      isDark: false,
    );
    MapMarker? best;
    var bestDistance = 28.0; // a fingertip, in logical pixels
    for (final marker in markers) {
      if (marker.onTap == null) continue;
      final at = painter._project(marker.position, size);
      final distance = (at - local).distance;
      if (distance < bestDistance) {
        best = marker;
        bestDistance = distance;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    // The tiles follow the skin the panel is wearing; the markers on them
    // never do, because they are the legend.
    final isDark = context.palette.isDark;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: _SchematicMapPainter(
              center: center,
              zoom: zoom,
              markers: markers,
              routes: [
                ...routes,
                if (route.length >= 2) MapRoute(points: route),
              ],
              circles: circles,
              textDirection: Directionality.of(context),
              isDark: isDark,
            ),
            isComplex: true,
            willChange: true,
          ),
          // Over the painting, so taps reach it; translucent, so a tap that
          // misses every marker still reaches whatever is underneath.
          if (markers.any((m) => m.onTap != null))
            LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) =>
                    _markerAt(details.localPosition, constraints.biggest)?.onTap?.call(),
              ),
            ),
          if (showAttribution)
            Positioned(
              left: Insets.sm,
              bottom: Insets.sm,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: (isDark ? const Color(0xFF23262B) : BrandColors.white)
                      .withValues(alpha: 0.82),
                  borderRadius: Corners.brXs,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Insets.sm,
                    vertical: 3,
                  ),
                  child: Text(
                    'Mapa esquemático',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? const Color(0xFFB4AFAE)
                              : BrandColors.grey600,
                          fontSize: 10,
                        ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SchematicMapPainter extends CustomPainter {
  _SchematicMapPainter({
    required this.center,
    required this.zoom,
    required this.markers,
    required this.routes,
    required this.circles,
    required this.textDirection,
    required this.isDark,
  });

  final LatLng center;
  final double zoom;
  final List<MapMarker> markers;
  final List<MapRoute> routes;
  final List<MapCircle> circles;
  final TextDirection textDirection;

  /// Which skin the tiles wear. Passed in rather than read from a context so
  /// the painter stays a plain painter. It touches the ground only — tiles,
  /// blocks, water, streets, casings, labels — never a marker, whose colours
  /// are the ones the legend names.
  final bool isDark;

  /// Web Mercator world size in pixels at this zoom, matching Google's 256-px
  /// tile scheme so marker separation reads at the right scale.
  double get _worldPx => 256 * math.pow(2, zoom).toDouble();

  Offset _project(LatLng p, Size size) {
    final world = _worldPx;
    double x(double lng) => (lng + 180) / 360 * world;
    double y(double lat) {
      final s = math.sin(lat * math.pi / 180).clamp(-0.9999, 0.9999);
      return (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi)) * world;
    }

    return Offset(
      size.width / 2 + (x(p.longitude) - x(center.longitude)),
      size.height / 2 + (y(p.latitude) - y(center.latitude)),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = isDark ? const Color(0xFF14161A) : const Color(0xFFF1EFEC),
    );

    // A deterministic seed keeps the "city" stable across rebuilds so the map
    // does not shimmer while a marker animates.
    final seed = (center.latitude * 1000).round() ^ (center.longitude * 1000).round();
    final rng = math.Random(seed);

    _paintBlocks(canvas, size, rng);
    _paintWater(canvas, size, rng);
    _paintStreets(canvas, size, rng);
    _paintCircles(canvas, size);
    _paintRoute(canvas, size);
    _paintMarkers(canvas, size);
  }

  void _paintCircles(Canvas canvas, Size size) {
    for (final circle in circles) {
      // Web Mercator: a metre covers more pixels the further from the equator.
      final metersPerPixel = math.cos(circle.center.latitude * math.pi / 180) *
          2 *
          math.pi *
          6378137 /
          _worldPx;
      final radius = circle.radiusMeters / metersPerPixel;
      final at = _project(circle.center, size);
      canvas
        ..drawCircle(
          at,
          radius,
          Paint()..color = circle.color.withValues(alpha: circle.fillOpacity),
        )
        ..drawCircle(
          at,
          radius,
          Paint()
            ..color = circle.color.withValues(alpha: circle.strokeOpacity)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
    }
  }

  void _paintBlocks(Canvas canvas, Size size, math.Random rng) {
    // Light: blocks a shade darker than the tile. Dark: a shade lighter, so
    // the grid still reads without anything on the ground going bright.
    final block = Paint()
      ..color = isDark ? const Color(0xFF1B1E24) : const Color(0xFFE7E4E0);
    const step = 78.0;
    for (var x = -step; x < size.width + step; x += step) {
      for (var y = -step; y < size.height + step; y += step) {
        if (rng.nextDouble() < 0.28) continue;
        final inset = 6 + rng.nextDouble() * 10;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + inset, y + inset, step - inset * 2, step - inset * 2),
            const Radius.circular(2),
          ),
          block,
        );
      }
    }

    // A couple of green blocks stand in for parks.
    final park = Paint()
      ..color = isDark ? const Color(0xFF1B2A20) : const Color(0xFFD9E5D2);
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            rng.nextDouble() * size.width,
            rng.nextDouble() * size.height,
            50 + rng.nextDouble() * 70,
            40 + rng.nextDouble() * 60,
          ),
          const Radius.circular(6),
        ),
        park,
      );
    }
  }

  void _paintWater(Canvas canvas, Size size, math.Random rng) {
    // The Ozama runs through Santo Domingo; every Dominican map has water.
    final path = Path()..moveTo(size.width * 0.12, -20);
    var y = -20.0;
    var x = size.width * 0.12;
    while (y < size.height + 20) {
      y += 60;
      x += (rng.nextDouble() - 0.45) * 70;
      path.quadraticBezierTo(x + 24, y - 30, x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = isDark ? const Color(0xFF16303E) : const Color(0xFFC5DCE8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.round,
    );
  }

  void _paintStreets(Canvas canvas, Size size, math.Random rng) {
    // At night the roads are lit a step above the ground rather than white:
    // a white grid at this density is the whole rectangle glowing.
    final secondary = Paint()
      ..color = isDark ? const Color(0xFF33383F) : BrandColors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    final arterial = Paint()
      ..color = isDark ? const Color(0xFF5A4A2E) : const Color(0xFFFBD9A0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    final highway = Paint()
      ..color = isDark ? const Color(0xFF6E4B2E) : const Color(0xFFF0A868)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13
      ..strokeCap = StrokeCap.round;

    const step = 78.0;
    for (var x = -step; x < size.width + step; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), secondary);
    }
    for (var y = -step; y < size.height + step; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), secondary);
    }

    // Two arterials and one diagonal highway — the Duarte, effectively.
    canvas
      ..drawLine(
        Offset(0, size.height * 0.34),
        Offset(size.width, size.height * 0.34),
        arterial,
      )
      ..drawLine(
        Offset(size.width * 0.62, 0),
        Offset(size.width * 0.62, size.height),
        arterial,
      )
      ..drawLine(
        Offset(-20, size.height * 0.86),
        Offset(size.width + 20, size.height * 0.12),
        highway,
      );
  }

  void _paintRoute(Canvas canvas, Size size) {
    for (final route in routes) {
      if (route.points.length < 2) continue;
      var path = Path();
      for (var i = 0; i < route.points.length; i++) {
        final point = _project(route.points[i], size);
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      if (route.dashed) path = _dashed(path);

      // Casing first, so the line reads over both road and block fills. It is
      // the contrast under the route, so it darkens rather than lightens.
      canvas
        ..drawPath(
          path,
          Paint()
            ..color = isDark ? const Color(0xFF0B0C0E) : BrandColors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 9
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        )
        ..drawPath(
          path,
          Paint()
            ..color = route.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
    }
  }

  static Path _dashed(Path source, {double dash = 14, double gap = 10}) {
    final out = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        out.addPath(
          metric.extractPath(distance, math.min(distance + dash, metric.length)),
          Offset.zero,
        );
        distance += dash + gap;
      }
    }
    return out;
  }

  void _paintMarkers(Canvas canvas, Size size) {
    for (final marker in markers) {
      final projected = _project(marker.position, size);
      // Still arriving: drawn above where it belongs, and falling.
      final point = marker.arrival >= 1
          ? projected
          : projected.translate(0, -34 * (1 - marker.arrival));
      switch (marker.kind) {
        case MapMarkerKind.pickup:
          _pin(canvas, point, BrandColors.red);
        case MapMarkerKind.dropoff:
          _pin(canvas, point, BrandColors.ink);
        case MapMarkerKind.customer:
          _pin(canvas, point, BrandColors.info);
        case MapMarkerKind.me:
          canvas.drawOval(
            Rect.fromCenter(center: point, width: 20, height: 7),
            Paint()..color = BrandColors.red.withValues(alpha: 0.25),
          );
          _pin(canvas, point, BrandColors.red, radius: 12);
        case MapMarkerKind.user:
          _userDot(canvas, point);
        case MapMarkerKind.truckIdle:
          _truck(canvas, point, BrandColors.driverIdle, marker.heading);
        case MapMarkerKind.truckOnService:
          _truck(canvas, point, BrandColors.driverOnService, marker.heading);
        case MapMarkerKind.truckStale:
          _truck(canvas, point, BrandColors.driverStale, marker.heading);
      }

      final label = marker.label;
      if (label != null && label.isNotEmpty) {
        _label(canvas, point, label);
      }
    }
  }

  void _pin(Canvas canvas, Offset at, Color color, {double radius = 9}) {
    final r = radius;
    final tip = at;
    final centre = Offset(at.dx, at.dy - r * 2.2);

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..quadraticBezierTo(centre.dx - r, centre.dy + r, centre.dx - r, centre.dy)
      ..arcToPoint(Offset(centre.dx + r, centre.dy), radius: Radius.circular(r))
      ..quadraticBezierTo(centre.dx + r, centre.dy + r, tip.dx, tip.dy)
      ..close();

    canvas
      ..drawPath(
        path,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      )
      ..drawPath(path, Paint()..color = color)
      ..drawCircle(centre, 3.4, Paint()..color = BrandColors.white);
  }

  void _userDot(Canvas canvas, Offset at) {
    canvas
      ..drawCircle(
        at,
        16,
        Paint()..color = BrandColors.red.withValues(alpha: 0.16),
      )
      ..drawCircle(at, 7, Paint()..color = BrandColors.white)
      ..drawCircle(at, 5, Paint()..color = BrandColors.red);
  }

  void _truck(Canvas canvas, Offset at, Color color, double heading) {
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..rotate(heading * math.pi / 180);

    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(-11, -8, 22, 16),
      const Radius.circular(4),
    );
    canvas
      ..drawRRect(
        body.shift(const Offset(0, 1)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.2)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
      )
      ..drawRRect(body, Paint()..color = color)
      ..drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-7, -5, 8, 10),
          const Radius.circular(2),
        ),
        Paint()..color = BrandColors.white,
      )
      // Nose triangle points the way the truck is heading.
      ..drawPath(
        Path()
          ..moveTo(11, -5)
          ..lineTo(16, 0)
          ..lineTo(11, 5)
          ..close(),
        Paint()..color = color,
      )
      ..restore();
  }

  void _label(Canvas canvas, Offset at, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: isDark ? const Color(0xFFF1EFEE) : BrandColors.ink,
        ),
      ),
      textDirection: textDirection,
    )..layout();

    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        at.dx - painter.width / 2 - 6,
        at.dy + 8,
        painter.width + 12,
        painter.height + 6,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(
      rect,
      Paint()
        ..color = (isDark ? const Color(0xFF23262B) : BrandColors.white)
            .withValues(alpha: 0.92),
    );
    painter
      ..paint(canvas, Offset(at.dx - painter.width / 2, at.dy + 11))
      ..dispose();
  }

  @override
  bool shouldRepaint(_SchematicMapPainter old) =>
      old.center != center ||
      old.zoom != zoom ||
      old.routes != routes ||
      old.markers != markers ||
      old.isDark != isDark;
}
