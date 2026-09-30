import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

/// A production build that is pointed somewhere wrong must fail at startup,
/// loudly, rather than quietly talk to the wrong place.
void main() {
  AppConfig config({
    Flavor flavor = Flavor.dev,
    String projectId = 'gruasrd-ce2ae',
    bool useEmulators = false,
  }) =>
      AppConfig(
        flavor: flavor,
        appKind: AppKind.driver,
        firebaseProjectId: projectId,
        googleMapsApiKey: 'key',
        useEmulators: useEmulators,
        emulatorHost: 'localhost',
        functionsRegion: 'us-east1',
      );

  test('a production build refuses the emulators', () {
    expect(
      () => config(flavor: Flavor.prod, useEmulators: true)
          .assertProductionReady(),
      throwsStateError,
    );
    expect(config(flavor: Flavor.prod).assertProductionReady, returnsNormally);
  });

  test('a production build refuses the dev project', () {
    expect(
      () => config(flavor: Flavor.prod, projectId: 'grua-rd-dev')
          .assertProductionReady(),
      throwsStateError,
    );
  });

  test('a development build is not held to production rules', () {
    expect(
      config(projectId: 'grua-rd-dev', useEmulators: true).assertProductionReady,
      returnsNormally,
    );
  });
}
