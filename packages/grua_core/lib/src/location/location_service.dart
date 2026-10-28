import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:geocoding/geocoding.dart' as geocoding;
import 'package:geolocator/geolocator.dart';

import '../domain/failures.dart';
import '../domain/value_objects.dart';
import 'script_geocoder.dart';

/// Why the app cannot use location right now, if it cannot.
///
/// Each case has a different fix, so they are separate rather than one
/// "denied": turning on the GPS radio, granting a prompt, and opening system
/// settings are three different instructions for the customer.
enum LocationBlocker {
  /// The device's location services are switched off entirely.
  serviceDisabled,

  /// Not asked yet.
  notRequested,

  /// Denied this time; asking again is allowed.
  denied,

  /// Denied permanently. Only a trip to system settings fixes it.
  deniedForever,

  /// Foreground granted, but the chofer app needs "always".
  needsAlways,

  none;

  bool get isBlocking => this != LocationBlocker.none;

  /// The es-DO explanation shown to the user.
  String get message => switch (this) {
        LocationBlocker.serviceDisabled =>
          'El GPS está apagado. Actívalo para que podamos encontrarte.',
        LocationBlocker.notRequested =>
          'Necesitamos tu ubicación para enviarte la grúa.',
        LocationBlocker.denied =>
          'Sin tu ubicación no podemos enviarte una grúa. Puedes marcarla en '
              'el mapa si prefieres.',
        LocationBlocker.deniedForever =>
          'Bloqueaste el acceso a la ubicación. Actívalo en los ajustes del '
              'teléfono.',
        LocationBlocker.needsAlways =>
          'Para recibir servicios necesitamos tu ubicación siempre, incluso '
              'con la app cerrada.',
        LocationBlocker.none => '',
      };

  /// What the button under that message should say.
  String? get actionLabel => switch (this) {
        LocationBlocker.serviceDisabled => 'Abrir ajustes de ubicación',
        LocationBlocker.notRequested || LocationBlocker.denied => 'Permitir',
        LocationBlocker.deniedForever ||
        LocationBlocker.needsAlways =>
          'Abrir ajustes',
        LocationBlocker.none => null,
      };
}

/// A resolved place: coordinates plus whatever the geocoder could name.
@immutable
class ResolvedPlace {
  const ResolvedPlace({
    required this.position,
    this.address = '',
    this.locality = '',
    this.isApproximate = false,
  });

  final LatLng position;
  final String address;
  final String locality;

  /// True when the address came from a last-known fix or a coarse geocode, so
  /// the UI can ask the customer to confirm rather than assume.
  final bool isApproximate;

  String get displayAddress =>
      address.isNotEmpty ? address : 'Ubicación en el mapa';
}

/// Device location, with the permission ladder handled once.
///
/// Dominican street addressing is unreliable, so nothing here treats a
/// geocoded string as authoritative — every caller pairs it with a map pin the
/// customer can drag and a landmark reference they type themselves.
class LocationService {
  LocationService({GeolocatorPlatform? geolocator, geocoding.Geocoding? geocoder})
      : _geolocator = geolocator ?? GeolocatorPlatform.instance,
        _injectedGeocoder = geocoder;

  final GeolocatorPlatform _geolocator;
  final geocoding.Geocoding? _injectedGeocoder;
  geocoding.Geocoding? _cachedGeocoder;

  /// Built on first use, not in the constructor.
  ///
  /// `Geocoding()` dereferences the platform instance eagerly and throws when
  /// none is registered — which is every widget test, and any host where the
  /// plugin failed to register. Constructing it lazily means a screen that
  /// never geocodes never pays for it, and a missing platform degrades to an
  /// unnamed pin instead of taking the provider down.
  geocoding.Geocoding? get _geocoder {
    if (_injectedGeocoder != null) return _injectedGeocoder;
    if (_cachedGeocoder != null) return _cachedGeocoder;
    try {
      return _cachedGeocoder = geocoding.Geocoding();
    } on Object {
      return null;
    }
  }

  /// Results come back in Dominican Spanish so a chofer reads "Calle" rather
  /// than "Street".
  static const Locale _locale = Locale('es', 'DO');

  /// How long a name is worth waiting for. The pin is already on the map by
  /// then, and the customer types a landmark reference regardless.
  static const Duration _geocodeLimit = Duration(seconds: 8);

  /// How long a permission prompt may stay open before we go and read the
  /// permission state ourselves.
  static const Duration _promptLimit = Duration(minutes: 2);

  /// Checks what, if anything, is stopping us — without prompting.
  ///
  /// Answers even when the platform will not. A browser with no Permissions
  /// API, or a host where the plugin never registered, throws out of
  /// `checkPermission`; letting that escape left every caller awaiting a
  /// future that never completed, which on the picker is a spinner that turns
  /// for ever. "Not asked yet" is the honest reading of a question the
  /// platform refused to answer, and it is the one that still lets the caller
  /// prompt.
  Future<LocationBlocker> check({bool requireAlways = false}) async {
    try {
      if (!await _geolocator.isLocationServiceEnabled()) {
        return LocationBlocker.serviceDisabled;
      }

      final permission = await _geolocator.checkPermission();
      return switch (permission) {
        LocationPermission.denied => LocationBlocker.notRequested,
        LocationPermission.deniedForever => LocationBlocker.deniedForever,
        LocationPermission.whileInUse =>
          requireAlways ? LocationBlocker.needsAlways : LocationBlocker.none,
        LocationPermission.always => LocationBlocker.none,
        LocationPermission.unableToDetermine => LocationBlocker.notRequested,
      };
    } on Object {
      return LocationBlocker.notRequested;
    }
  }

  /// Prompts, and reports what we ended up with.
  ///
  /// Callers must show their own rationale *before* calling this: on both
  /// platforms a denied prompt is close to unrecoverable, so spending it
  /// without explaining why is a permanent loss.
  Future<LocationBlocker> request({bool requireAlways = false}) async {
    try {
      if (!await _geolocator.isLocationServiceEnabled()) {
        return LocationBlocker.serviceDisabled;
      }

      var permission = await _geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.unableToDetermine) {
        // On the web this prompt *is* a position request, so a phone that
        // grants it and then never gets a fix leaves it pending — the browser
        // gives up after a day. Long enough for anyone to read the dialog and
        // decide, then we ask the permission state itself, which answers
        // whether or not a fix ever arrived.
        permission = await _geolocator.requestPermission().timeout(
              _promptLimit,
              onTimeout: _geolocator.checkPermission,
            );
      }

      return switch (permission) {
        LocationPermission.denied => LocationBlocker.denied,
        LocationPermission.deniedForever => LocationBlocker.deniedForever,
        LocationPermission.whileInUse =>
          requireAlways ? LocationBlocker.needsAlways : LocationBlocker.none,
        LocationPermission.always => LocationBlocker.none,
        LocationPermission.unableToDetermine => LocationBlocker.denied,
      };
    } on Object {
      return LocationBlocker.denied;
    }
  }

  /// Opens the OS location settings, where there are any to open.
  ///
  /// Both of these throw `UnsupportedError` on the web — an `Error`, not an
  /// `Exception`, so a caller's `on Exception` would not have caught it. There
  /// is nothing to open in a browser, and a button that does nothing beats one
  /// that takes the screen down with it.
  Future<void> openLocationSettings() async {
    try {
      await _geolocator.openLocationSettings();
    } on Object {
      // No settings screen on this platform.
    }
  }

  Future<void> openAppSettings() async {
    try {
      await _geolocator.openAppSettings();
    } on Object {
      // No settings screen on this platform.
    }
  }

  /// A single fix.
  ///
  /// Falls back to the last known position rather than failing: somebody
  /// stranded on a highway would rather see an approximate pin they can drag
  /// than a spinner while the GPS gets a lock.
  Future<Result<ResolvedPlace>> currentPlace({
    Duration timeout = const Duration(seconds: 10),
    bool geocode = true,
  }) async {
    final blocker = await check();
    if (blocker.isBlocking) {
      return Result.err(
        Failure(FailureCode.permissionDenied, message: blocker.message),
      );
    }

    final fix = await _fix(timeout);
    if (fix == null) {
      return const Result.err(
        Failure(
          FailureCode.timeout,
          message: 'No pudimos obtener tu ubicación. Márcala en el mapa.',
        ),
      );
    }

    final point = LatLng(fix.position.latitude, fix.position.longitude);
    if (!geocode) {
      return Result.ok(
        ResolvedPlace(position: point, isApproximate: fix.approximate),
      );
    }

    final place = await describe(point);
    return Result.ok(
      ResolvedPlace(
        position: point,
        address: place.address,
        locality: place.locality,
        isApproximate: fix.approximate,
      ),
    );
  }

  /// One fix, or null, and never anything else — not an exception, not a
  /// future that stays pending.
  ///
  /// Two web-only traps live here, and both showed up as a spinner that never
  /// stopped. `getLastKnownPosition` throws `UnsupportedError` in a browser,
  /// and an `Error` is not an `Exception`, so the fallback took the whole call
  /// down with it rather than being caught. And `timeLimit` is never applied
  /// there: geolocator_web hands the browser a timeout in the wrong unit, so
  /// ten seconds becomes the best part of three hours. Hence a Dart-side
  /// deadline, and `on Object` around every step.
  Future<({Position position, bool approximate})?> _fix(Duration timeout) async {
    try {
      final position = await _geolocator
          .getCurrentPosition(
            locationSettings: LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: timeout,
            ),
          )
          // A moment behind the platform's own limit, so where that one works
          // its TimeoutException — and its last-known fallback — still win.
          .timeout(timeout + const Duration(seconds: 2));
      return (position: position, approximate: false);
    } on Object {
      final last = await _lastKnown();
      return last == null ? null : (position: last, approximate: true);
    }
  }

  /// The last fix the platform kept, or null where it keeps none.
  Future<Position?> _lastKnown() async {
    try {
      return await _geolocator.getLastKnownPosition();
    } on Object {
      return null;
    }
  }

  /// One fix now, with no name attached.
  ///
  /// The chofer's publisher needs this the moment they go online: a position
  /// *stream* only emits once the phone has moved far enough, and in a browser
  /// often not at all while parked. Without a first fix a chofer who switches
  /// on and waits is invisible to dispatch and to the customer's "grúas cerca
  /// de ti" — online on their own screen, absent from everyone else's.
  ///
  /// Falls back to the last known position, and finally to null: a truck at a
  /// roughly right place beats a truck nowhere.
  Future<Position?> currentPosition({
    Duration timeout = const Duration(seconds: 10),
  }) async =>
      (await _fix(timeout))?.position;

  /// Reverse-geocodes a point. Never throws — an unnamed pin is still usable,
  /// and the customer types a landmark reference anyway.
  Future<ResolvedPlace> describe(LatLng point) async {
    try {
      final geocoder = _geocoder;
      if (geocoder == null) {
        // No plugin: the web, where the page's own Maps script can answer.
        final named = await scriptReverseGeocode(
          point.latitude,
          point.longitude,
        ).timeout(_geocodeLimit);
        return ResolvedPlace(position: point, address: named ?? '');
      }

      final results = await geocoder
          .placemarkFromCoordinates(
            point.latitude,
            point.longitude,
            locale: _locale,
          )
          .timeout(_geocodeLimit);
      if (results.isEmpty) return ResolvedPlace(position: point);

      final mark = results.first;
      final parts = [
        if ((mark.thoroughfare ?? '').isNotEmpty) mark.thoroughfare,
        if ((mark.subThoroughfare ?? '').isNotEmpty) mark.subThoroughfare,
        if ((mark.subLocality ?? '').isNotEmpty) mark.subLocality,
        if ((mark.locality ?? '').isNotEmpty) mark.locality,
      ].whereType<String>().toList();

      return ResolvedPlace(
        position: point,
        address: parts.join(', '),
        locality: mark.locality ?? '',
      );
    } on Object {
      // Including an `Error`: a plugin that is not there on this platform
      // throws one, and an unnamed pin is still a usable pin.
      return ResolvedPlace(position: point);
    }
  }

  /// A continuous position stream for the chofer app.
  ///
  /// [distanceFilter] keeps a parked truck from emitting; the caller throttles
  /// on top of this so a moving truck writes at most once every few seconds.
  Stream<Position> watchPosition({
    int distanceFilter = 25,
    bool background = false,
  }) {
    final LocationSettings settings;
    if (!background) {
      settings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
      );
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS keeps delivering in the background only when asked to, and only
      // for a stream started in the foreground with the "location" background
      // mode in Info.plist. Without this, a chofer who switches to WhatsApp
      // freezes on the customer's map. The blue status-bar pill is iOS's
      // equivalent of the Android notification, and lets "while in use" do.
      settings = AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
        activityType: ActivityType.automotiveNavigation,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: true,
        pauseLocationUpdatesAutomatically: false,
      );
    } else {
      settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
        // Without a foreground service Android stops delivering updates
        // within minutes of the screen going off, which for a chofer means
        // vanishing from dispatch mid-shift.
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Drakegruas Express',
          notificationText: 'Compartiendo tu ubicación mientras trabajas',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }

    return _geolocator.getPositionStream(locationSettings: settings);
  }

  /// Distance in metres between two points, without a plugin round-trip.
  double distanceBetween(LatLng a, LatLng b) => a.distanceTo(b);
}
