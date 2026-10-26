import 'package:flutter/material.dart';

/// The "Gruas RD 24/7" brand mark.
///
/// Shipped as a raster inside this package rather than each app's own assets,
/// so all three products draw the identical artwork and none of them has to
/// re-declare the file. [size] is the width; the height follows the artwork's
/// own ratio so the mark never distorts.
class GruaLogo extends StatelessWidget {
  const GruaLogo({this.size = 96, super.key});

  /// The rendered width. Height follows from [artworkRatio].
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icons/logo.png',
      package: 'grua_core',
      width: size,
      height: size * artworkRatio,
      fit: BoxFit.contain,
      // The mark is the only thing identifying the app on the splash and login
      // screens, so it carries meaning and is not decorative.
      semanticLabel: 'Drakegruas Express 24/7',
    );
  }

  /// The source artwork is 1218x1292. Keep this in step when the asset is
  /// replaced: BoxFit.contain means a stale value letterboxes rather than
  /// distorts, so the mark just sits in a box slightly the wrong shape.
  ///
  /// Exposed so callers sizing the mark off layout constraints can solve for
  /// a width that fits a given height.
  static const double artworkRatio = 1292 / 1218;
}
