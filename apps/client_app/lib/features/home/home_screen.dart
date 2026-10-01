import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import '../../router.dart';
import '../rating/rate_driver.dart';
import 'truck_search.dart';
import 'truck_search_widgets.dart';

/// The customer's home, and the Inicio tab.
///
/// A live map fills the screen, the mark sits at the top, and the bottom
/// carries the only two things somebody who has just broken down needs: the
/// search for grúas nearby, and the button that asks for one. Everything else
/// a customer might want — their services, their conversations, their account
/// — moved to the tabs under it, so this screen stays one decision deep.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Bumped by the locate button to rebuild the map on a fresh camera after
  /// the customer has panned away.
  var _epoch = 0;

  /// One turn of the radar: a ring is born at the customer, reaches the edge
  /// of the search radius, and fades.
  static const _sweep = Duration(milliseconds: 2400);

  /// Three rings in the air at once, evenly spaced through the turn.
  static const _rings = 3;

  /// How long a truck takes to drop onto its spot on the map.
  static const _arrival = Duration(milliseconds: 420);

  /// Redraws the radar. Twelve frames a second: enough for the rings to
  /// travel smoothly, few enough that the platform map is not rebuilt at
  /// screen rate for an ornament.
  Timer? _radar;

  /// When each truck was first seen, so only new ones drop in. Keyed by the
  /// sealed handle the search hands out, which names one truck.
  final _firstSeen = <String, DateTime>{};

  void _syncRadar(bool searching) {
    if (searching && _radar == null) {
      _radar = Timer.periodic(const Duration(milliseconds: 80), (_) {
        if (mounted) setState(() {});
      });
    } else if (!searching) {
      _radar?.cancel();
      _radar = null;
    }
  }

  @override
  void dispose() {
    _radar?.cancel();
    super.dispose();
  }

  /// The rings travelling out from the customer while the search runs.
  List<MapCircle> _radarRings(LatLng centre, double radiusMeters) {
    final turn = clock.now().millisecondsSinceEpoch % _sweep.inMilliseconds;
    return [
      for (var i = 0; i < _rings; i++)
        () {
          final progress = (turn / _sweep.inMilliseconds + i / _rings) % 1;
          return MapCircle(
            center: centre,
            // Starts as a dot on the customer rather than at nothing, which
            // the map draws as a full-screen fill.
            radiusMeters: radiusMeters * (0.04 + 0.96 * progress),
            fillOpacity: 0,
            // Brightest as it leaves, gone as it lands on the edge.
            strokeOpacity: 0.5 * (1 - progress) * (1 - progress),
          );
        }(),
    ];
  }

  /// How far through its arrival each truck is: 1 for one that was already
  /// there, climbing from 0 for one this check just found.
  double _arrivalOf(NearbyTruck truck, DateTime now) {
    final seen = _firstSeen.putIfAbsent(truck.ref, () => now);
    final elapsed = now.difference(seen).inMilliseconds;
    if (elapsed >= _arrival.inMilliseconds) return 1;
    final t = elapsed / _arrival.inMilliseconds;
    // Eased so it falls quickly and settles, rather than sliding at one speed.
    return 1 - (1 - t) * (1 - t);
  }

  Future<void> _resolveLocation(LocationBlocker blocker) async {
    final location = ref.read(locationServiceProvider);
    switch (blocker) {
      case LocationBlocker.serviceDisabled:
        await location.openLocationSettings();
      case LocationBlocker.deniedForever || LocationBlocker.needsAlways:
        await location.openAppSettings();
      case _:
        await location.request();
    }
    ref.invalidate(locationBlockerProvider);
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider).value;

    // The customer where their phone says they are — the red drop, as on the
    // chofer's map. Until the first fix the map shows the default centre with
    // nobody on it, rather than a pin pretending to be them.
    final me = ref.watch(myPositionProvider).value;
    final blocker = ref.watch(locationBlockerProvider).value;

    // "Grúas cerca de ti". The trucks are reassurance, not something to pick
    // from: dispatch chooses the chofer, and letting a customer aim at one
    // would be a promise the cascade cannot keep.
    final search = ref.watch(truckSearchProvider);
    final radiusKm = ref.watch(truckSearchSettingsProvider).radiusKm;
    final area = search.center == null
        ? null
        : MapCircle(center: search.center!, radiusMeters: radiusKm * 1000);

    final now = clock.now();
    // Trucks that have gone stay gone: a handle that comes back later is a
    // truck arriving again, and it should drop in again.
    _firstSeen.removeWhere(
      (ref, _) => !search.results.any((truck) => truck.ref == ref),
    );
    final arrivals = {
      for (final truck in search.results) truck.ref: _arrivalOf(truck, now),
    };
    // Kept redrawing a moment past the end of the search, so a truck found on
    // the last check lands rather than freezing in mid-air.
    _syncRadar(search.isSearching || arrivals.values.any((a) => a < 1));

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: GruaMap(
              key: ValueKey(_epoch),
              center: me?.position ?? DoLocations.defaultCenter,
              hasApiKey: ref.watch(hasMapsKeyProvider),
              zoom: me == null ? 13.4 : 15,
              // The camera frames the area searched, so every truck found is
              // on screen however wide the radius.
              circles: [
                ?area,
                if (search.isSearching && search.center != null)
                  ..._radarRings(search.center!, radiusKm * 1000),
              ],
              fitTo: area?.extremes ?? const [],
              markers: [
                for (final truck in search.results)
                  MapMarker(
                    // Named, so the map keeps a truck the same marker as the
                    // list around it changes — and so it drops in once.
                    id: truck.ref,
                    position: truck.position,
                    kind: MapMarkerKind.truckIdle,
                    heading: truck.heading,
                    arrival: arrivals[truck.ref] ?? 1,
                    onTap: () =>
                        unawaited(showNearbyTruckSheet(context, truck)),
                  ),
                if (me != null)
                  MapMarker(
                    position: me.position,
                    kind: MapMarkerKind.me,
                    label: 'Tú',
                  ),
              ],
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  greeting: user == null ? 'Hola' : 'Hola, ${user.shortName}',
                  onProfile: () => context.go(Routes.profile),
                ),
                const SizedBox(height: Insets.sm),
                // The mark over the map, as on the chofer's home. It lets
                // touches through, so the map still pans under it.
                // Gives way on a short screen rather than pushing the
                // cards below off it.
                const Flexible(
                  child: IgnorePointer(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: GruaLogo(size: 120),
                    ),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Insets.gutter,
                    0,
                    Insets.gutter,
                    Insets.md,
                  ),
                  child: blocker != null && blocker.isBlocking
                      ? InlineNotice(
                          message: switch (blocker) {
                            LocationBlocker.notRequested ||
                            LocationBlocker.denied =>
                              'Permite tu ubicación para verte en el mapa.',
                            _ => blocker.message,
                          },
                          icon: Icons.location_off_outlined,
                          actionLabel: blocker.actionLabel,
                          onAction: () => _resolveLocation(blocker),
                        )
                      : Align(
                          alignment: Alignment.centerRight,
                          child: Material(
                            color: BrandColors.white,
                            shape: const CircleBorder(),
                            elevation: 2,
                            child: IconButton(
                              tooltip: 'Centrar en mi ubicación',
                              onPressed: me == null
                                  ? null
                                  : () => setState(() => _epoch++),
                              icon: const Icon(Icons.my_location, size: 20),
                            ),
                          ),
                        ),
                ),
                // The last tow's rating, when it is still owed: the router
                // brings the customer here the moment a tow closes.
                const PendingDriverRating(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: Insets.gutter),
                  child: FloatingCard(
                    padding: EdgeInsets.symmetric(vertical: Insets.xs),
                    child: NearbyTrucksRow(),
                  ),
                ),
                const SizedBox(height: Insets.lg),
                _RequestBar(onRequest: () => context.push(Routes.request)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.greeting, required this.onProfile});

  final String greeting;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.gutter,
        Insets.md,
        Insets.gutter,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: FloatingCard(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.lg,
                vertical: Insets.md,
              ),
              borderRadius: Corners.brMd,
              child: Row(
                children: [
                  const Icon(
                    Icons.location_on,
                    size: 18,
                    color: BrandColors.red,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      greeting,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: Insets.md),
          FloatingCard(
            padding: const EdgeInsets.all(Insets.md),
            borderRadius: Corners.brMd,
            onTap: onProfile,
            child: const Icon(Icons.person_outline, color: BrandColors.ink),
          ),
        ],
      ),
    );
  }
}

class _RequestBar extends StatelessWidget {
  const _RequestBar({required this.onRequest});

  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.gutter,
        0,
        Insets.gutter,
        Insets.lg,
      ),
      child: ElevatedButton.icon(
        onPressed: onRequest,
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          padding: const EdgeInsets.symmetric(vertical: Insets.sm),
          shape: const RoundedRectangleBorder(borderRadius: Corners.brLg),
        ),
        icon: const Icon(Icons.local_shipping, size: 22),
        label: const Text('PEDIR GRÚA 24/7'),
      ),
    );
  }
}
