import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

/// The most the server takes on one transition (`photoPaths.max(6)`).
const maxProofPhotos = 6;

/// Photographs the vehicle before it is loaded or after it is handed over, and
/// uploads the photos. Returns their storage paths, or null when the chofer
/// backs out.
///
/// These are the record of the vehicle's condition: the moment it stops being
/// the customer's word and starts being ours. So they come from the camera,
/// never the gallery — an old photo of an undamaged car proves nothing — and
/// the job cannot move on without at least one.
Future<List<String>?> captureProofPhotos(
  BuildContext context, {
  required String serviceId,
  required ServicePhotoStage stage,
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  isDismissible: false,
  backgroundColor: Colors.transparent,
  builder: (_) => ProofPhotosSheet(serviceId: serviceId, stage: stage),
);

class ProofPhotosSheet extends ConsumerStatefulWidget {
  const ProofPhotosSheet({
    required this.serviceId,
    required this.stage,
    super.key,
  });

  final String serviceId;
  final ServicePhotoStage stage;

  @override
  ConsumerState<ProofPhotosSheet> createState() => _ProofPhotosSheetState();
}

class _ProofPhotosSheetState extends ConsumerState<ProofPhotosSheet> {
  final _photos = <PickedPhoto>[];

  /// How many have gone up, while uploading; null otherwise.
  int? _uploaded;
  String? _error;

  bool get _uploading => _uploaded != null;

  Future<void> _take() async {
    final photo = await ref.read(photoPickerProvider)(PhotoSource.camera);
    if (photo == null || !mounted) return;
    setState(() {
      _photos.add(photo);
      _error = null;
    });
  }

  /// Uploads in order and hands back every path, or stays open on the first
  /// failure: a transition that silently drops the photo of the dent the
  /// customer later disputes is worse than one that asks again.
  Future<void> _submit() async {
    final services = ref.read(serviceRepositoryProvider);
    setState(() {
      _uploaded = 0;
      _error = null;
    });

    final paths = <String>[];
    for (final photo in _photos) {
      final result = await services.uploadServicePhoto(
        serviceId: widget.serviceId,
        stage: widget.stage,
        bytes: photo.bytes,
        contentType: photo.contentType,
      );
      if (!mounted) return;
      switch (result) {
        case Ok(:final value):
          paths.add(value);
          setState(() => _uploaded = paths.length);
        case Err(:final failure):
          setState(() {
            _uploaded = null;
            _error = 'No se pudo subir una foto. ${failure.userMessage}';
          });
          return;
      }
    }
    Navigator.of(context).pop(paths);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final pickup = widget.stage == ServicePhotoStage.pickup;
    final full = _photos.length >= maxProofPhotos;

    return BottomActionSheet(
      child: Column(
        key: Key('proof-photos-${widget.stage.wire}'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: FieldLabel(
              pickup ? 'Fotos antes de cargar' : 'Fotos al entregar',
            ),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            pickup
                ? 'Fotografía el vehículo antes de subirlo a la grúa: frente, '
                      'lados, parte trasera y cualquier golpe que ya tenga.'
                : 'Fotografía el vehículo donde lo dejas, con cualquier golpe '
                      'visible, antes de finalizar.',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: BrandColors.grey800),
          ),
          const SizedBox(height: Insets.lg),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              for (var i = 0; i < _photos.length; i++)
                _Thumb(
                  key: Key('proof-photo-$i'),
                  photo: _photos[i],
                  onRemove: _uploading
                      ? null
                      : () => setState(() => _photos.removeAt(i)),
                ),
              if (!full)
                _AddTile(
                  key: const Key('proof-photo-add'),
                  onTap: _uploading ? null : () => unawaited(_take()),
                ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          Text(
            '${_photos.length} de $maxProofPhotos · mínimo 1',
            style: text.bodySmall?.copyWith(color: BrandColors.grey600),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: Insets.md),
            InlineNotice(message: error, tone: NoticeTone.error),
          ],
          const SizedBox(height: Insets.xl),
          ElevatedButton(
            key: const Key('proof-photos-submit'),
            onPressed: _photos.isEmpty || _uploading ? null : _submit,
            child: _uploading
                ? Text('SUBIENDO $_uploaded DE ${_photos.length}…')
                : Text(pickup ? 'INICIAR SERVICIO' : 'FINALIZAR SERVICIO'),
          ),
          const SizedBox(height: Insets.sm),
          TextButton(
            onPressed: _uploading ? null : () => Navigator.of(context).pop(),
            child: const Text('Todavía no'),
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.photo, required this.onRemove, super.key});

  final PickedPhoto photo;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 88,
    child: Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: Corners.brMd,
          child: Image.memory(
            photo.bytes,
            fit: BoxFit.cover,
            // A format this device cannot draw still uploads fine.
            errorBuilder: (_, _, _) => const ColoredBox(
              color: BrandColors.grey200,
              child: Icon(Icons.image_outlined, color: BrandColors.grey600),
            ),
          ),
        ),
        if (onRemove != null)
          Positioned(
            top: 2,
            right: 2,
            child: IconButton.filledTonal(
              tooltip: 'Quitar foto',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: onRemove,
              icon: const Icon(Icons.close),
            ),
          ),
      ],
    ),
  );
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap, super.key});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Tomar foto',
    child: InkWell(
      onTap: onTap,
      borderRadius: Corners.brMd,
      child: Ink(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          color: BrandColors.redTint,
          borderRadius: Corners.brMd,
          border: Border.all(color: BrandColors.red),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_camera_outlined, color: BrandColors.red),
            SizedBox(height: Insets.xxs),
            Text(
              'Tomar foto',
              style: TextStyle(fontSize: 12, color: BrandColors.red),
            ),
          ],
        ),
      ),
    ),
  );
}
