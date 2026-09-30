import 'package:flutter/material.dart';

import '../brand.dart';
import '../palette.dart';

/// The photos a customer took of their vehicle, as a row of thumbnails.
///
/// What the chofer looks at to know what they are driving to: a car on its
/// side and a car with a flat are different jobs. Tapping one opens it full
/// screen, where it can be zoomed. Draws nothing when there are no photos.
class VehiclePhotoStrip extends StatelessWidget {
  const VehiclePhotoStrip({required this.urls, this.size = 64, super.key});

  /// Download URLs, or data URIs from the test backend.
  final List<String> urls;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (urls.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: size,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        separatorBuilder: (_, _) => const SizedBox(width: Insets.sm),
        itemBuilder: (context, index) => Semantics(
          button: true,
          label: 'Foto del vehículo ${index + 1}',
          child: InkWell(
            key: Key('vehicle-photo-$index'),
            borderRadius: Corners.brMd,
            onTap: () => showVehiclePhotos(context, urls, initial: index),
            child: ClipRRect(
              borderRadius: Corners.brMd,
              child: SizedBox.square(
                dimension: size,
                child: VehiclePhoto(url: urls[index], fit: BoxFit.cover),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One vehicle photo, from the bucket or, in a test, a data URI.
class VehiclePhoto extends StatelessWidget {
  const VehiclePhoto({required this.url, this.fit = BoxFit.contain, super.key});

  final String url;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget broken(BuildContext _, Object _, StackTrace? _) => ColoredBox(
          color: palette.surfaceSubtle,
          child: Center(
            child: Icon(Icons.broken_image_outlined, color: palette.textFaint),
          ),
        );

    if (url.startsWith('data:')) {
      final bytes = Uri.tryParse(url)?.data?.contentAsBytes();
      if (bytes == null) return broken(context, url, null);
      return Image.memory(bytes, fit: fit, errorBuilder: broken);
    }

    return Image.network(
      url,
      fit: fit,
      // The web renderer decodes images itself, which needs CORS headers the
      // bucket does not send by default; an <img> element needs none.
      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
      errorBuilder: broken,
      loadingBuilder: (context, child, progress) => progress == null
          ? child
          : ColoredBox(
              color: palette.surfaceSubtle,
              child: const Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
    );
  }
}

/// Opens the photos full screen, starting at [initial], swipeable and
/// zoomable.
Future<void> showVehiclePhotos(
  BuildContext context,
  List<String> urls, {
  int initial = 0,
}) =>
    showDialog<void>(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => _PhotoViewer(urls: urls, initial: initial),
    );

class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.urls, required this.initial});

  final List<String> urls;
  final int initial;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _pages = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      key: const Key('vehicle-photo-viewer'),
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            itemCount: widget.urls.length,
            onPageChanged: (index) => setState(() => _index = index),
            itemBuilder: (context, index) => InteractiveViewer(
              maxScale: 5,
              child: Center(child: VehiclePhoto(url: widget.urls[index])),
            ),
          ),
          SafeArea(
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Cerrar',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Spacer(),
                if (widget.urls.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(right: Insets.lg),
                    child: Text(
                      '${_index + 1} / ${widget.urls.length}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
