import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

/// Picks a point on the map.
///
/// The map moves and the pin stays fixed in the centre. That is the opposite of
/// dragging a marker, and it is the right way round on a phone: the pin never
/// ends up under the thumb that is placing it, and the target is always the
/// same spot on screen.
///
/// The address is never fetched by moving the map. Panning used to
/// reverse-geocode on a debounce, which billed a lookup for every place the
/// map paused over on the way to the one the customer wanted, and rewrote the
/// field under them while they were reading it — often with a Plus Code, which
/// is what Google returns for a corner with no street number. Naming the point
/// is one deliberate tap on the map's own button.
///
/// The result is shown as *editable* text and paired with a mandatory landmark
/// reference at pickup, because Dominican street addressing is unreliable
/// enough that a reverse-geocoded string is a hint, not an answer.
class LocationPickerScreen extends ConsumerStatefulWidget {
  const LocationPickerScreen({
    required this.title,
    required this.initial,
    this.requireReference = false,
    super.key,
  });

  final String title;
  final ServiceLocation? initial;

  /// Pickup needs a landmark; a destination usually does not.
  final bool requireReference;

  @override
  ConsumerState<LocationPickerScreen> createState() =>
      _LocationPickerScreenState();
}

class _LocationPickerScreenState extends ConsumerState<LocationPickerScreen> {
  final _address = TextEditingController();
  final _reference = TextEditingController();

  late LatLng _center;
  Timer? _suggestDebounce;
  var _resolving = false;
  var _locating = false;
  String? _error;

  /// The point the address on screen describes, when it came from the map or
  /// from a chosen suggestion. Null while the field holds what the customer
  /// typed themselves — their own words are never stale.
  LatLng? _namedPoint;

  /// What the typed text matches, newest answer only.
  var _suggestions = <PlaceSuggestion>[];

  /// Bumped per keystroke, so a slow answer to an older query is dropped
  /// rather than replacing the list under the customer's finger.
  var _suggestQuery = 0;

  @override
  void initState() {
    super.initState();
    // Open where the phone already knows it is, rather than at the centre of
    // Santo Domingo: the position stream on the home map and the fix taken
    // for the pickup are both resolved by now, and waiting on a fresh
    // `getCurrentPosition` left the map sitting on the wrong city for
    // seconds, then animating across it.
    _center = widget.initial?.geo ?? _positionAlreadyKnown() ??
        DoLocations.defaultCenter;
    _address.text = widget.initial?.address ?? '';
    if (widget.initial != null) _namedPoint = widget.initial!.geo;
    _reference.text = widget.initial?.reference ?? '';
    if (widget.initial == null) unawaited(_useCurrentLocation());
  }

  /// A position some other screen has already paid for, if there is one.
  LatLng? _positionAlreadyKnown() =>
      ref.read(myPositionProvider).value?.position ??
      ref.read(currentPlaceProvider).value?.position;

  @override
  void dispose() {
    _suggestDebounce?.cancel();
    _address.dispose();
    _reference.dispose();
    super.dispose();
  }

  /// Records where the map is looking. It does **not** fetch an address.
  ///
  /// Only the "that address is not this pin any more" hint can change here, and
  /// only a rebuild when it actually flips — a drag fires idle events by the
  /// dozen, and each one used to cost a geocode.
  void _onCameraIdle(LatLng center) {
    final wasStale = _pinMoved;
    _center = center;
    if (_pinMoved != wasStale) setState(() {});
  }

  /// True when the address on screen was resolved for a point the pin has
  /// since left. Fifteen metres is about one house: inside that, the same
  /// address still describes where the pin is.
  bool get _pinMoved {
    final named = _namedPoint;
    return named != null && named.distanceTo(_center) > 15;
  }

  /// Names the point the pin is on — the screen's only reverse geocode, and it
  /// happens because the customer asked for it.
  Future<void> _nameThisPoint() async {
    FocusScope.of(context).unfocus();

    // The point as it was when the button was pressed: the answer belongs to
    // it, not to wherever the map has drifted to by the time it lands.
    final asked = _center;
    setState(() {
      _resolving = true;
      _error = null;
      _suggestions = const [];
    });

    try {
      final place = await ref.read(locationServiceProvider).describe(asked);
      if (!mounted) return;

      if (place.address.isEmpty) {
        setState(
          () => _error = 'No pudimos encontrar el nombre de este punto. '
              'Escribe la dirección o una referencia.',
        );
        return;
      }

      setState(() {
        _address.text = place.address;
        _namedPoint = asked;
      });
    } finally {
      // In a `finally` because a spinner is a promise that something is
      // happening: if the geocoder throws, nothing is, and the customer must
      // be able to type the address themselves.
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Asks for suggestions a moment after the typing stops.
  ///
  /// Debounced because every call is billed and a five-letter street would
  /// otherwise cost five of them; biased to where the map is looking, so
  /// "Duarte" offers the one in this city first.
  void _onAddressTyped(String value) {
    // Typed words describe whatever the customer means by them, so there is
    // no point they can drift away from.
    if (_namedPoint != null) setState(() => _namedPoint = null);
    _suggestDebounce?.cancel();

    if (value.trim().length < 2) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }

    _suggestDebounce = Timer(const Duration(milliseconds: 250), () async {
      final query = ++_suggestQuery;
      List<PlaceSuggestion> found;
      try {
        found = await ref.read(placesServiceProvider).suggest(value, near: _center);
      } on Object {
        // No network, no key, no matches — the customer types the address.
        found = const [];
      }
      if (!mounted || query != _suggestQuery) return;
      setState(() => _suggestions = found);
    });
  }

  /// Takes the chosen place as the answer: the map goes there, the field says
  /// its name, and the list closes.
  Future<void> _choose(PlaceSuggestion suggestion) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _suggestions = const [];
      _resolving = true;
    });

    ResolvedPlace? place;
    try {
      place = await ref.read(placesServiceProvider).details(suggestion.placeId);
    } on Object {
      // A lookup that failed is not worth an error over the map: the name the
      // customer tapped is below, and the pin is still draggable.
      place = null;
    }
    if (!mounted) return;

    setState(() {
      _resolving = false;
      if (place == null) {
        // The name is still worth keeping; the pin stays where it was and the
        // customer can drag it.
        _address.text = suggestion.title;
        return;
      }
      _center = place.position;
      _namedPoint = place.position;
      _address.text = place.address.isNotEmpty ? place.address : suggestion.title;
    });
  }

  Future<void> _useCurrentLocation() async {
    setState(() {
      _locating = true;
      _error = null;
    });

    try {
      final service = ref.read(locationServiceProvider);
      var blocker = await service.check();
      if (blocker == LocationBlocker.notRequested) {
        blocker = await service.request();
      }

      if (!mounted) return;

      if (blocker.isBlocking) {
        setState(() => _error = blocker.message);
        return;
      }

      // No geocode: opening the picker moves the map to where the phone is,
      // and naming a point is the button's job, not the camera's.
      final result = await service.currentPlace(geocode: false);
      if (!mounted) return;

      result.fold(
        (place) => setState(() => _center = place.position),
        (failure) => setState(() => _error = failure.userMessage),
      );
    } on Object {
      // Nothing in LocationService throws any more, but this button owns the
      // only spinner on the screen and it has no other way to stop. A vague
      // error the customer can act on beats one that never arrives.
      if (mounted) {
        setState(() => _error = 'No pudimos obtener tu ubicación. Márcala en '
            'el mapa.');
      }
    } finally {
      // The bug this replaces: every path that stopped the spinner was a
      // happy one. A permission check that threw — `getLastKnownPosition`
      // throws `UnsupportedError` on the web — or a browser that never
      // answered `getCurrentPosition` skipped all of them, and the button span
      // until the screen was closed.
      if (mounted) setState(() => _locating = false);
    }
  }

  /// The button carries the only spinner on the screen: the opening fix and
  /// the geocode both run behind it.
  bool get _busy => _locating || _resolving;

  Future<void> _openSettings() async {
    final service = ref.read(locationServiceProvider);
    final blocker = await service.check();
    if (blocker == LocationBlocker.serviceDisabled) {
      await service.openLocationSettings();
    } else {
      await service.openAppSettings();
    }
  }

  void _confirm() {
    if (widget.requireReference && _reference.text.trim().isEmpty) {
      setState(() => _error = 'Escribe una referencia para que el chofer te '
          'encuentre.');
      return;
    }

    Navigator.of(context).pop(
      ServiceLocation(
        geo: _center,
        address: _address.text.trim(),
        reference: _reference.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasApiKey = ref.watch(hasMapsKeyProvider);

    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          Expanded(
            // Every child is positioned. A Stack takes the size of its
            // unpositioned children, and the pin alone is 44 px wide — which
            // is exactly how wide the map became.
            child: Stack(
              children: [
                Positioned.fill(
                  child: GruaMap(
                    center: _center,
                    hasApiKey: hasApiKey,
                    zoom: 16,
                    onCameraIdle: _onCameraIdle,
                    // No marker at the centre: the fixed pin below is the
                    // pointer, and a second one would be two truths.
                    markers: const [],
                  ),
                ),
                const Positioned.fill(child: Center(child: _CentrePin())),
                // Bottom *left*, above the attribution: on the web Google
                // draws its own pan and zoom cluster in the bottom-right
                // corner the moment the map takes focus, and it sat squarely
                // on top of this button.
                Positioned(
                  left: Insets.lg,
                  bottom: Insets.huge,
                  child: Tooltip(
                    message: 'Usar este punto',
                    child: FloatingCard(
                      key: const Key('name-this-point'),
                      padding: const EdgeInsets.all(Insets.md),
                      borderRadius: Corners.brMd,
                      onTap: _busy ? null : _nameThisPoint,
                      child: _busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.2),
                            )
                          : const Icon(
                              Icons.pin_drop_outlined,
                              color: BrandColors.red,
                            ),
                    ),
                  ),
                ),
                // The matches sit directly above the address field, over the
                // bottom of the map, the way a search bar's dropdown does.
                if (_suggestions.isNotEmpty)
                  Positioned(
                    left: Insets.lg,
                    right: Insets.lg,
                    bottom: Insets.md,
                    child: _SuggestionList(
                      suggestions: _suggestions,
                      onChosen: _choose,
                    ),
                  ),
                if (!hasApiKey)
                  const Positioned(
                    top: Insets.md,
                    left: Insets.lg,
                    right: Insets.lg,
                    child: InlineNotice(
                      message: 'Mapa esquemático: arrastra para elegir el '
                          'punto. Con la llave de Google Maps configurada verás '
                          'el mapa real.',
                      icon: Icons.map_outlined,
                      tone: NoticeTone.info,
                    ),
                  ),
              ],
            ),
          ),
          BottomActionSheet(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const FieldLabel('Dirección'),
                const SizedBox(height: Insets.sm),
                TextField(
                  key: const Key('address-field'),
                  controller: _address,
                  textInputAction: TextInputAction.search,
                  onChanged: _onAddressTyped,
                  decoration: const InputDecoration(
                    hintText: 'Escribe, elige un lugar o usa el pin del mapa',
                  ),
                ),
                if (_pinMoved) ...[
                  const SizedBox(height: Insets.sm),
                  // Otherwise the customer confirms an address that names
                  // somewhere they have already panned away from.
                  Row(
                    children: [
                      const Icon(
                        Icons.pin_drop_outlined,
                        size: 16,
                        color: BrandColors.grey600,
                      ),
                      const SizedBox(width: Insets.xs),
                      Expanded(
                        child: Text(
                          'Moviste el mapa. Toca el pin para obtener la '
                          'dirección de este punto.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: BrandColors.grey600,
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: Insets.md),
                FieldLabel(
                  widget.requireReference
                      ? 'Referencia (obligatoria)'
                      : 'Referencia (opcional)',
                ),
                const SizedBox(height: Insets.sm),
                TextField(
                  controller: _reference,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  decoration: const InputDecoration(
                    hintText: 'Frente al colmado, km 12 Autopista Duarte…',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: Insets.md),
                  InlineNotice(
                    message: _error!,
                    tone: NoticeTone.error,
                    actionLabel: _error!.contains('ajustes') ? 'Abrir' : null,
                    onAction:
                        _error!.contains('ajustes') ? _openSettings : null,
                  ),
                ],
                const SizedBox(height: Insets.lg),
                ElevatedButton(
                  onPressed: _confirm,
                  child: const Text('CONFIRMAR UBICACIÓN'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What the typed address matches, nearest the map's centre first.
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.suggestions, required this.onChosen});

  final List<PlaceSuggestion> suggestions;
  final ValueChanged<PlaceSuggestion> onChosen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Material(
      key: const Key('address-suggestions'),
      color: BrandColors.white,
      borderRadius: Corners.brMd,
      elevation: 6,
      child: ConstrainedBox(
        // Five rows at most: a list that covers the map hides the thing the
        // customer is aiming at.
        constraints: const BoxConstraints(maxHeight: 260),
        child: ListView.separated(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: suggestions.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: BrandColors.grey100),
          itemBuilder: (context, index) {
            final suggestion = suggestions[index];
            return ListTile(
              dense: true,
              leading: const Icon(
                Icons.place_outlined,
                color: BrandColors.grey600,
              ),
              title: Text(
                suggestion.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleSmall,
              ),
              subtitle: suggestion.subtitle.isEmpty
                  ? null
                  : Text(
                      suggestion.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: BrandColors.grey600,
                      ),
                    ),
              onTap: () => onChosen(suggestion),
            );
          },
        ),
      ),
    );
  }
}

/// The fixed pin at the centre of the map, with a shadow that stays put while
/// the pin lifts — the standard cue that the map is what is moving.
class _CentrePin extends StatelessWidget {
  const _CentrePin();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.location_on, size: 44, color: BrandColors.red),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.28),
              shape: BoxShape.circle,
            ),
          ),
          // Offsets the pin so its tip, not its centre, sits on the target.
          const SizedBox(height: 44),
        ],
      ),
    );
  }
}
