import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import '../shared/toast.dart';

/// Places suggested by name when the Places API is not configured.
///
/// Empty in the product: without Google's suggestions the operator points at
/// the place on the map, rather than choosing from a list somebody typed in.
/// A test hands the form its own places here.
final knownPlacesProvider = Provider<List<ServiceLocation>>((ref) => const []);

/// Lowercase and without accents, so "agora" finds "Ágora".
String _fold(String s) {
  const from = 'áéíóúüñ';
  const to = 'aeiouun';
  final lower = s.toLowerCase();
  final out = StringBuffer();
  for (final ch in lower.split('')) {
    final i = from.indexOf(ch);
    out.write(i < 0 ? ch : to[i]);
  }
  return out.toString();
}

/// One place on the order form: typed with suggestions, or pointed at on a
/// map. [onChanged] gets the place, or null once the text no longer
/// describes a chosen point.
class AddressField extends ConsumerStatefulWidget {
  const AddressField({
    required this.label,
    required this.onChanged,
    required this.fieldKey,
    this.hint = '',
    this.value,
    this.labelInside = true,
    super.key,
  });

  /// Names the place — in the field, and as the map picker's title.
  final String label;
  final String hint;

  /// False where the form puts its labels above the fields: the label then
  /// only titles the map picker, and the field shows its hint.
  final bool labelInside;
  final ServiceLocation? value;
  final ValueChanged<ServiceLocation?> onChanged;

  /// Prefix for the keys of the field and its parts, so a test can drive it.
  final String fieldKey;

  @override
  ConsumerState<AddressField> createState() => _AddressFieldState();
}

class _AddressFieldState extends ConsumerState<AddressField> {
  late final _text = TextEditingController(text: widget.value?.address ?? '');
  final _focus = FocusNode();
  Timer? _debounce;
  var _query = 0;
  List<({String title, String subtitle, Future<ServiceLocation?> Function() pick})>
      _suggestions = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _typed(String value) {
    // Their own words no longer name the chosen point.
    if (widget.value != null && value != widget.value!.address) {
      widget.onChanged(null);
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _suggest(value));
  }

  Future<void> _suggest(String value) async {
    final query = ++_query;
    final places = ref.read(placesServiceProvider);
    final text = value.trim();
    if (text.length < 2) {
      if (mounted) setState(() => _suggestions = const []);
      return;
    }

    if (!places.isAvailable) {
      final folded = _fold(text);
      final matches = [
        for (final place in ref.read(knownPlacesProvider))
          if (_fold(place.address).contains(folded))
            (
              title: place.address,
              subtitle: 'Lugar frecuente',
              pick: () async => place,
            ),
      ];
      if (mounted && query == _query) setState(() => _suggestions = matches);
      return;
    }

    final found = await places.suggest(text, near: DoLocations.defaultCenter);
    if (!mounted || query != _query) return;
    setState(() {
      _suggestions = [
        for (final s in found)
          (
            title: s.title,
            subtitle: s.subtitle,
            pick: () async {
              final resolved = await places.details(s.placeId);
              if (resolved == null) return null;
              final name = [s.title, s.subtitle].where((p) => p.isNotEmpty).join(', ');
              return ServiceLocation(
                geo: resolved.position,
                address: name,
                placeId: s.placeId,
              );
            },
          ),
      ];
    });
  }

  Future<void> _choose(Future<ServiceLocation?> Function() pick) async {
    final place = await pick();
    if (!mounted) return;
    if (place == null) {
      showToast(
        context,
        'No pudimos ubicar ese lugar. Elígelo en el mapa.',
        tone: ToastTone.error,
      );
      return;
    }
    _text.text = place.address;
    setState(() => _suggestions = const []);
    widget.onChanged(place);
  }

  Future<void> _pickOnMap() async {
    final picked = await showDialog<ServiceLocation>(
      context: context,
      builder: (_) => _MapPickerDialog(
        title: widget.label,
        initial: widget.value,
        typed: _text.text.trim(),
      ),
    );
    if (picked == null || !mounted) return;
    _text.text = picked.address;
    setState(() => _suggestions = const []);
    widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    final chosen = widget.value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: Key('${widget.fieldKey}-input'),
          controller: _text,
          focusNode: _focus,
          onChanged: _typed,
          decoration: InputDecoration(
            labelText: widget.labelInside ? widget.label : null,
            hintText: widget.hint,
            prefixIcon: Icon(
              chosen == null ? Icons.search : Icons.place,
              color: chosen == null ? null : palette.brand,
            ),
            suffixIcon: IconButton(
              key: Key('${widget.fieldKey}-map'),
              tooltip: 'Elegir en el mapa',
              onPressed: _pickOnMap,
              icon: const Icon(Icons.map_outlined),
            ),
          ),
        ),
        if (_suggestions.isNotEmpty)
          Material(
            elevation: 2,
            borderRadius: Corners.brSm,
            child: Column(
              children: [
                for (final (i, s) in _suggestions.take(6).indexed)
                  ListTile(
                    key: Key('${widget.fieldKey}-suggestion-$i'),
                    dense: true,
                    leading: const Icon(Icons.place_outlined, size: 18),
                    title: Text(s.title),
                    subtitle: s.subtitle.isEmpty ? null : Text(s.subtitle),
                    onTap: () => _choose(s.pick),
                  ),
              ],
            ),
          ),
        const SizedBox(height: Insets.xxs),
        Text(
          chosen == null
              ? 'Escribe y elige una sugerencia, o marca el punto en el mapa.'
              : 'Ubicado: ${chosen.geo.latitude.toStringAsFixed(5)}, '
                  '${chosen.geo.longitude.toStringAsFixed(5)}',
          key: Key('${widget.fieldKey}-status'),
          style: text.bodySmall?.copyWith(
            color: chosen == null ? palette.textMuted : palette.success,
          ),
        ),
      ],
    );
  }
}

/// A map with a fixed pin in the middle: move the map under it, then use
/// that point.
class _MapPickerDialog extends ConsumerStatefulWidget {
  const _MapPickerDialog({required this.title, required this.initial, required this.typed});

  final String title;
  final ServiceLocation? initial;
  final String typed;

  @override
  ConsumerState<_MapPickerDialog> createState() => _MapPickerDialogState();
}

class _MapPickerDialogState extends ConsumerState<_MapPickerDialog> {
  late LatLng _center = widget.initial?.geo ?? DoLocations.defaultCenter;
  late final _address = TextEditingController(
    text: widget.initial?.address ?? widget.typed,
  );
  var _naming = false;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _name() async {
    setState(() => _naming = true);
    final place = await ref.read(placesServiceProvider).describePoint(_center);
    if (!mounted) return;
    setState(() => _naming = false);
    if (place != null && place.address.isNotEmpty) _address.text = place.address;
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = ref.watch(hasMapsKeyProvider);
    final canName = ref.watch(placesServiceProvider).isAvailable;

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 360,
              child: ClipRRect(
                borderRadius: Corners.brMd,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    GruaMap(
                      center: _center,
                      hasApiKey: hasKey,
                      zoom: 16,
                      onCameraIdle: (center) => setState(() => _center = center),
                    ),
                    // The pin stands on the centre of the map.
                    const IgnorePointer(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: 36),
                        child: Icon(Icons.location_on, size: 40, color: BrandColors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Insets.md),
            TextField(
              key: const Key('map-picker-address'),
              controller: _address,
              decoration: InputDecoration(
                labelText: 'Dirección o referencia',
                suffixIcon: canName
                    ? IconButton(
                        tooltip: 'Nombrar este punto',
                        onPressed: _naming ? null : _name,
                        icon: const Icon(Icons.my_location),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          key: const Key('map-picker-use'),
          onPressed: () => Navigator.of(context).pop(
            ServiceLocation(
              geo: _center,
              address: _address.text.trim().isEmpty ? 'Punto en el mapa' : _address.text.trim(),
            ),
          ),
          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 40)),
          child: const Text('Usar este punto'),
        ),
      ],
    );
  }
}
