import 'dart:typed_data';

import 'package:client_app/features/request/request_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// The photos a customer adds to a request.
///
/// The bug: they were picked, shown on the form, and never sent anywhere — the
/// request went out without them, so the chofer had nothing to look at.
void main() {
  final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 4, 5, 6]);

  late DemoBackend backend;

  ProviderContainer containerWith(Future<Uint8List> Function(String path) read) {
    backend = DemoBackend()..seed();
    final container = ProviderContainer(
      overrides: [
        ...demoOverrides(backend: backend),
        currentUserIdProvider.overrideWithValue(backend.currentUserId),
        photoBytesReaderProvider.overrideWithValue(read),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// A filled-in, priced form with two photos on it.
  Future<RequestController> fillIn(ProviderContainer container) async {
    final controller = container.read(requestControllerProvider.notifier)
      ..setPickup(
        const ServiceLocation(geo: LatLng(18.4712, -69.9061), address: 'Naco'),
      )
      ..setDropoff(
        const ServiceLocation(geo: LatLng(18.5001, -69.8800), address: 'Taller'),
      )
      ..setVehicle(const ServiceVehicle(make: 'Toyota', model: 'Corolla'))
      ..addPhoto('picked/front.png')
      ..addPhoto('picked/side.jpg');
    await controller.requestQuote();
    expect(container.read(requestControllerProvider).quote, isNotNull);
    return controller;
  }

  test('the photos are uploaded and travel on the request', () async {
    final files = {'picked/front.png': png, 'picked/side.jpg': jpeg};
    final container = containerWith((path) async => files[path]!);
    final controller = await fillIn(container);

    final serviceId = await controller.submit();

    expect(container.read(requestControllerProvider).failure, isNull);
    expect(serviceId, isNotNull);
    final photos = backend.service(serviceId!)!.vehicle.photoPaths;
    expect(photos, [
      UriData.fromBytes(png, mimeType: 'image/png').toString(),
      UriData.fromBytes(jpeg, mimeType: 'image/jpeg').toString(),
    ]);
  });

  test('a photo that cannot be read stops the request and says so', () async {
    final container = containerWith((path) async => throw StateError('gone'));
    final controller = await fillIn(container);

    final serviceId = await controller.submit();

    expect(serviceId, isNull);
    final draft = container.read(requestControllerProvider);
    expect(draft.submitting, isFalse);
    expect(draft.failure?.userMessage, contains('fotos'));
  });

  test('the image type is read from the bytes, not the name', () {
    expect(imageContentType(png), 'image/png');
    expect(imageContentType(jpeg), 'image/jpeg');
    expect(
      imageContentType(Uint8List.fromList('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits)),
      'image/webp',
    );
  });
}
