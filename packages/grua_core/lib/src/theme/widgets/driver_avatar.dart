import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../domain/models/driver.dart';
import '../brand.dart';
import '../palette.dart';

/// A chofer's face, with their availability as a dot on the bottom-right.
///
/// Falls back to initials when there is no photo or it will not load: an
/// account opened before photos were asked for, or a file the platform cannot
/// decode, must still leave a row the office recognises.
class DriverAvatar extends StatelessWidget {
  const DriverAvatar({
    required this.name,
    this.photoUrl = '',
    this.bytes,
    this.presence,
    this.size = 40,
    super.key,
  });

  /// The roster's avatar: the chofer's stored photo and live presence.
  /// [appOpen] is whether the chofer has the app running right now.
  DriverAvatar.of(
    Driver driver, {
    bool appOpen = false,
    double size = 40,
    Key? key,
  }) : this(
          name: driver.name,
          photoUrl: driver.photoUrl,
          presence: driver.presence(appOpen: appOpen),
          size: size,
          key: key,
        );

  final String name;
  final String photoUrl;

  /// A photo picked but not uploaded yet. Wins over [photoUrl].
  final Uint8List? bytes;

  /// Null hides the dot, as on a registration form.
  final DriverPresence? presence;

  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final state = presence;
    final dot = (size * 0.3).clamp(10.0, 24.0);

    return Semantics(
      label: state == null ? name : '$name, ${state.label}',
      image: true,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            ClipOval(child: SizedBox.square(dimension: size, child: _image())),
            if (state != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: Tooltip(
                  message: state.label,
                  child: Container(
                    width: dot,
                    height: dot,
                    decoration: BoxDecoration(
                      color: state.color,
                      shape: BoxShape.circle,
                      // The ring separates the dot from a photo of any colour.
                      border: Border.all(color: palette.surface, width: 2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _image() {
    final initials = _Initials(name: name, size: size);
    Widget fallback(BuildContext _, Object _, StackTrace? _) => initials;

    final picked = bytes;
    if (picked != null) {
      return Image.memory(
        picked,
        key: ValueKey(picked),
        fit: BoxFit.cover,
        errorBuilder: fallback,
      );
    }
    if (photoUrl.isEmpty) return initials;

    // The test backend has no bucket, so its photos travel as data URIs.
    if (photoUrl.startsWith('data:')) {
      final decoded = Uri.tryParse(photoUrl)?.data?.contentAsBytes();
      if (decoded == null) return initials;
      return Image.memory(
        decoded,
        key: ValueKey(photoUrl),
        fit: BoxFit.cover,
        errorBuilder: fallback,
      );
    }

    return Image.network(
      photoUrl,
      // Keyed by the photo itself. A list that drops a row — a chofer
      // deleted — shifts every row below it up, and Flutter then updates the
      // image element in place with the next chofer's URL. Until that photo
      // arrives the element keeps painting the frame it already had, which
      // put the deleted chofer's face on the row below. A key tied to the
      // source retires the old element instead of feeding it a new URL.
      key: ValueKey(photoUrl),
      fit: BoxFit.cover,
      // The web renderer decodes images itself, which needs CORS headers the
      // bucket does not send by default; an <img> element needs none.
      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
      errorBuilder: fallback,
    );
  }
}

/// The dot's colours: green, yellow, red, as the office reads a traffic light.
/// Green means reachable — app open — whether or not the switch is on; the
/// label beside it says which.
extension DriverPresenceColor on DriverPresence {
  Color get color => switch (this) {
        DriverPresence.online || DriverPresence.connected => BrandColors.success,
        DriverPresence.busy => const Color(0xFFF2B600),
        DriverPresence.offline => BrandColors.danger,
      };
}

class _Initials extends StatelessWidget {
  const _Initials({required this.name, required this.size});

  final String name;
  final double size;

  /// First letters of the first two words — the same two `shortName` shows.
  String get _letters {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final second = parts.length > 1 ? parts[1].characters.first : '';
    return (first + second).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ColoredBox(
      color: palette.surfaceSubtle,
      child: Center(
        child: Text(
          _letters,
          style: TextStyle(
            color: palette.textStrong,
            fontSize: size * 0.38,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
