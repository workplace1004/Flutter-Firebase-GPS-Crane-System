import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:grua_testing/grua_testing.dart';

/// Voice calls between a customer and their chofer.
///
/// The phone button on the chofer's service screen and the customer's
/// "Llamar" used to show "Llamando a …" and nothing else. These run a whole
/// call, both sides, on the in-memory backend: the customer's side through the
/// real controller, the chofer's side straight on the backend, which is what
/// their app would do on its own phone.
///
/// `testWidgets` rather than `test` for its fake clock: a call rings for 45
/// seconds before it counts as missed, and the screen lingers after hanging up.
void main() {
  const client = 'demo-client-1';
  const pickup = ServiceLocation(
    geo: LatLng(18.4795, -69.9420),
    address: 'Gazcue',
  );

  late DemoBackend backend;
  late String driverId;
  late Service service;
  late SilentVoiceTransport transport;
  late ProviderContainer container;

  /// A tow in progress: the one window where the two may call each other.
  void setUpService({bool assign = true, Exception? micError}) {
    backend = DemoBackend(dispatchDelay: const Duration(hours: 1))..seed();
    service = backend.createService(
      clientId: client,
      pickup: pickup,
      dropoff: const ServiceLocation(geo: LatLng(18.5001, -69.8800)),
      vehicle: const ServiceVehicle(condition: VehicleCondition.noArranca),
      truckType: TruckType.gancho,
      quote: const Quote(totalCents: 250000),
      route: const ServiceRoute(distanceMeters: 8000),
    );
    driverId = backend.allDrivers
        .firstWhere(
          (d) => d.truckType == TruckType.gancho && d.status.canWork && !d.isBusy,
        )
        .id;
    if (assign) {
      expect(
        backend.assignServiceManually(serviceId: service.id, driverId: driverId),
        isNull,
      );
    }

    transport = SilentVoiceTransport(prepareError: micError);
    container = ProviderContainer(
      overrides: [
        ...demoOverrides(
          backend: backend,
          actingAs: client,
          // One the test can inspect.
          voiceTransport: () => transport,
        ),
        currentUserIdProvider.overrideWithValue(client),

      ],
    )
      // Kept alive the way the app keeps it: watched from the root.
      ..listen(callControllerProvider, (_, _) {});
  }

  CallSession session() => container.read(callControllerProvider);
  CallController controller() => container.read(callControllerProvider.notifier);
  VoiceCall onlyCall() => backend.allCalls.single;

  Future<void> settle(WidgetTester tester, [Duration by = const Duration(milliseconds: 500)]) =>
      tester.pump(by);

  /// Runs [action] while the fake clock moves: every server call in demo mode
  /// waits a moment, and awaiting one without pumping would wait forever.
  Future<void> run(WidgetTester tester, Future<void> action) async {
    await settle(tester);
    await action;
  }

  void tearDownAll() {
    container.dispose();
    backend.dispose();
  }

  group('placing a call', () {
    testWidgets('rings the chofer, connects when answered, ends for both', (tester) async {
      setUpService();

      final placing = controller().call(serviceId: service.id, peerName: 'Chofer');
      expect(session().phase, CallPhase.outgoing, reason: 'shown before the server answers');
      await settle(tester);
      await placing;

      // It rings on the chofer's side.
      expect(onlyCall().state, CallState.ringing);
      expect(onlyCall().calleeId, driverId);
      expect(session().peerName, isNotEmpty);
      // The caller waits in the room, so the audio is ready when they answer.
      expect(transport.connected, isTrue);

      // The chofer answers on their phone.
      backend.answerCall(onlyCall().id, driverId);
      await settle(tester);
      expect(session().phase, CallPhase.active);
      expect(session().connectedAt, isNotNull);

      await run(tester, controller().hangUp());
      await settle(tester);
      expect(session().phase, CallPhase.ended);
      expect(session().message, 'Llamada terminada');
      expect(onlyCall().state, CallState.ended);
      expect(transport.connected, isFalse);

      // The screen clears itself.
      await settle(tester, CallController.endedLinger);
      expect(session().isIdle, isTrue);

      tearDownAll();
    });

    testWidgets('says so when the chofer declines', (tester) async {
      setUpService();
      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      backend.endCall(onlyCall().id, driverId, EndCallReason.declined);
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(session().message, 'No contestó');
      expect(transport.connected, isFalse);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('gives up after ringing out, and records it as missed', (tester) async {
      setUpService();
      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      await settle(tester, VoiceCall.ringLimit + const Duration(seconds: 1));

      expect(session().message, 'Sin respuesta');
      expect(onlyCall().state, CallState.missed);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('hanging up while it rings cancels it on the other phone', (tester) async {
      setUpService();
      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      await run(tester, controller().hangUp());
      await settle(tester);

      expect(session().message, 'Llamada cancelada');
      expect(onlyCall().state, CallState.cancelled);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('is refused before a chofer has accepted, with a reason', (tester) async {
      setUpService(assign: false);

      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(session().message, isNotEmpty);
      expect(backend.allCalls, isEmpty);
      expect(transport.connected, isFalse);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('a second call on the same service is refused', (tester) async {
      setUpService();
      // The chofer is already ringing the customer.
      backend.startCall(service.id, driverId);
      await settle(tester);
      // The customer's screen shows it ringing; a new call must not start.
      expect(session().phase, CallPhase.incoming);

      expect(backend.startCall(service.id, client), isA<Err<CallJoin>>());
      tearDownAll();
    });
  });

  group('the microphone', () {
    // What the chofer hit: the call reached the customer's phone and rang, and
    // the chofer's own screen said the microphone could not be used. The
    // microphone was only asked for after the other phone was already ringing,
    // and any audio failure was blamed on it.

    testWidgets('refused when calling: nobody is rung', (tester) async {
      setUpService(micError: Exception('NotAllowedError: Permission denied'));

      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      expect(backend.allCalls, isEmpty, reason: 'the other phone never rang');
      expect(session().phase, CallPhase.ended);
      expect(session().message, CallAudioProblem.permission.message);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('refused when answering: the call is declined, not accepted', (tester) async {
      setUpService(micError: Exception('NotAllowedError: Permission denied'));
      backend.startCall(service.id, driverId);
      await settle(tester);
      expect(session().phase, CallPhase.incoming);

      await run(tester, controller().answer());
      await settle(tester);

      // The caller hears "No contestó" rather than waiting on a silent line.
      expect(onlyCall().state, CallState.declined);
      expect(session().message, CallAudioProblem.permission.message);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    test('says what actually went wrong', () {
      // Web: a browser DOMException, known only by its name.
      expect(CallAudioProblem.of(Exception('NotAllowedError: Permission denied')),
          CallAudioProblem.permission);
      expect(CallAudioProblem.of(Exception('NotFoundError: Requested device not found')),
          CallAudioProblem.noMicrophone);
      expect(CallAudioProblem.of(Exception('NotReadableError: Could not start audio source')),
          CallAudioProblem.microphoneBusy);
      expect(
        CallAudioProblem.of(Exception("Cannot read properties of undefined (reading 'getUserMedia')")),
        CallAudioProblem.unknown,
      );
      // Not every failure is the microphone.
      expect(CallAudioProblem.of(Exception('websocket closed')), CallAudioProblem.connection);
      expect(CallAudioProblem.of(Exception('something odd')), CallAudioProblem.unknown);
    });
  });

  group('being called', () {
    testWidgets('rings wherever the customer is, and connects on answer', (tester) async {
      setUpService();

      backend.startCall(service.id, driverId);
      await settle(tester);

      expect(session().phase, CallPhase.incoming);
      expect(session().peerName, onlyCall().callerName);

      final answering = controller().answer();
      expect(session().phase, CallPhase.connecting);
      await settle(tester);
      await answering;

      expect(onlyCall().state, CallState.accepted);
      expect(session().phase, CallPhase.active);
      expect(transport.connected, isTrue);

      // The chofer hangs up.
      backend.endCall(onlyCall().id, driverId, EndCallReason.hangup);
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(session().message, 'Llamada terminada');
      expect(transport.connected, isFalse);
      await settle(tester, CallController.endedLinger);
      expect(session().isIdle, isTrue);
      tearDownAll();
    });

    testWidgets('declining tells the caller', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId);
      await settle(tester);

      await run(tester, controller().decline());
      await settle(tester);

      expect(onlyCall().state, CallState.declined);
      expect(session().phase, CallPhase.ended);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('stops ringing when the caller gives up', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId);
      await settle(tester);
      expect(session().phase, CallPhase.incoming);

      backend.endCall(onlyCall().id, driverId, EndCallReason.cancelled);
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(session().message, 'Llamada cancelada');
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });
  });

  group('on the line', () {
    testWidgets('the other person dropping ends it for both', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId);
      await settle(tester);
      await run(tester, controller().answer());
      await settle(tester);
      expect(session().phase, CallPhase.active);

      transport.simulatePeerLeft();
      await settle(tester);

      expect(session().phase, CallPhase.ended);
      expect(onlyCall().state, CallState.ended);
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('mute and speaker reach the audio', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId);
      await settle(tester);
      await run(tester, controller().answer());
      await settle(tester);

      await controller().toggleMute();
      await controller().toggleSpeaker();

      expect(session().muted, isTrue);
      expect(transport.muted, isTrue);
      expect(session().speaker, isTrue);
      expect(transport.speaker, isTrue);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      tearDownAll();
    });
  });

  group('video calls', () {
    testWidgets('placing one rings as video and takes the camera first', (tester) async {
      setUpService();

      await run(
        tester,
        controller().call(serviceId: service.id, peerName: 'Chofer', video: true),
      );
      await settle(tester);

      expect(onlyCall().video, isTrue, reason: 'the other phone rings as video');
      expect(transport.preparedVideo, isTrue);
      expect(session().video, isTrue);
      expect(session().cameraOn, isTrue);

      backend.answerCall(onlyCall().id, driverId);
      await settle(tester);
      expect(session().phase, CallPhase.active);
      // Held at arm's length: out of the loudspeaker.
      expect(session().speaker, isTrue);

      await controller().toggleCamera();
      expect(session().cameraOn, isFalse);
      expect(transport.cameraOn, isFalse);
      await controller().switchCamera();
      expect(transport.cameraSwitches, 1);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      tearDownAll();
    });

    testWidgets('being video-called answers with the camera', (tester) async {
      setUpService();
      backend.startCall(service.id, driverId, video: true);
      await settle(tester);

      expect(session().phase, CallPhase.incoming);
      expect(session().video, isTrue);

      await run(tester, controller().answer());
      await settle(tester);
      expect(transport.preparedVideo, isTrue);
      expect(session().phase, CallPhase.active);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      tearDownAll();
    });

    testWidgets('a voice call never takes the camera', (tester) async {
      setUpService();
      await run(tester, controller().call(serviceId: service.id, peerName: 'Chofer'));
      await settle(tester);

      expect(onlyCall().video, isFalse);
      expect(transport.preparedVideo, isFalse);
      await controller().toggleCamera();
      expect(session().cameraOn, isFalse);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      tearDownAll();
    });

    testWidgets('a refused camera says camera, not only microphone', (tester) async {
      setUpService(micError: Exception('NotAllowedError: Permission denied'));

      await run(
        tester,
        controller().call(serviceId: service.id, peerName: 'Chofer', video: true),
      );
      await settle(tester);

      expect(backend.allCalls, isEmpty);
      expect(session().message, CallAudioProblem.permission.messageFor(video: true));
      expect(session().message, contains('cámara'));
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });

    testWidgets('the screen shows the video controls on the line', (tester) async {
      setUpService();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => CallLayer(child: child!),
            home: const Scaffold(body: Text('mapa')),
          ),
        ),
      );

      backend.startCall(service.id, driverId, video: true);
      await settle(tester);
      expect(find.text('Videollamada entrante'), findsOneWidget);

      await tester.tap(find.byKey(const Key('call-answer')));
      await settle(tester);

      expect(find.byKey(const Key('call-camera')), findsOneWidget);
      expect(find.byKey(const Key('call-switch-camera')), findsOneWidget);
      expect(find.byKey(const Key('call-mute')), findsOneWidget);
      // No picture from the other side in a test: it says so instead.
      expect(find.byKey(const Key('call-peer-camera-off')), findsOneWidget);

      // Camera off: nothing to flip.
      await tester.tap(find.byKey(const Key('call-camera')));
      await settle(tester);
      expect(find.byKey(const Key('call-switch-camera')), findsNothing);

      await tester.tap(find.byKey(const Key('call-hangup')));
      await settle(tester);
      await settle(tester, CallController.endedLinger);
      expect(find.byKey(const Key('call-screen')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      tearDownAll();
    });
  });

  group('in a chat before any job', () {
    late String requestId;

    /// A customer and the chofer of a nearby truck, talking before a tow is
    /// requested. [accept] is whether the chofer answered yes.
    void setUpChat({bool accept = true}) {
      setUpService(assign: false);
      final chofer = backend.allDrivers
          .firstWhere((d) => d.id != driverId && d.status.canWork && !d.isBusy);
      driverId = chofer.id;
      backend.setDriverOnline(driverId, online: true);
      requestId = backend
          .createChatRequest(clientId: client, driverId: driverId)
          .valueOrNull!;
      if (accept) {
        expect(
          backend.respondChatRequest(requestId, driverId, accept: true),
          isA<Ok<void>>(),
        );
      }
    }

    testWidgets('a video call rings the chofer once they accepted', (tester) async {
      setUpChat();

      await run(
        tester,
        controller().call(chatRequestId: requestId, peerName: 'Chofer', video: true),
      );
      await settle(tester);

      expect(onlyCall().chatRequestId, requestId);
      expect(onlyCall().serviceId, isEmpty);
      expect(onlyCall().calleeId, driverId);
      expect(onlyCall().video, isTrue);
      expect(transport.preparedVideo, isTrue);

      backend.answerCall(onlyCall().id, driverId);
      await settle(tester);
      expect(session().phase, CallPhase.active);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      expect(onlyCall().state, CallState.ended);
      tearDownAll();
    });

    testWidgets('the chofer can call the customer too', (tester) async {
      setUpChat();

      backend.startChatRequestCall(requestId, driverId, video: true);
      await settle(tester);

      expect(session().phase, CallPhase.incoming);
      expect(session().video, isTrue);
      tearDownAll();
    });

    testWidgets('nobody rings before the chofer accepts', (tester) async {
      setUpChat(accept: false);

      await run(
        tester,
        controller().call(chatRequestId: requestId, peerName: 'Chofer', video: true),
      );
      await settle(tester);

      expect(backend.allCalls, isEmpty);
      expect(session().message, contains('conversación está abierta'));
      await settle(tester, CallController.endedLinger);
      tearDownAll();
    });
  });

  group('the ripple around the avatar', () {
    testWidgets('travels while the other person talks, and stops with them', (
      tester,
    ) async {
      setUpService();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => CallLayer(child: child!),
            home: const Scaffold(body: Text('mapa')),
          ),
        ),
      );

      backend.startCall(service.id, driverId);
      await settle(tester);
      await tester.tap(find.byKey(const Key('call-answer')));
      await settle(tester);
      expect(session().phase, CallPhase.active);

      CustomPaint ripple() => tester.widget<CustomPaint>(
            find.descendant(
              of: find.byKey(const Key('call-speaking')),
              matching: find.byType(CustomPaint),
            ),
          );

      // Silence draws nothing at all.
      expect((ripple().painter! as dynamic).level, 0.0);

      transport.speakingLevel = 0.8;
      // One frame takes the new level in, the next moves the ease along.
      await settle(tester, Duration.zero);
      await settle(tester, const Duration(milliseconds: 400));
      final speaking = (ripple().painter! as dynamic).level as double;
      expect(speaking, greaterThan(0.5));

      // The rings keep travelling while they talk.
      final turn = (ripple().painter! as dynamic).turn as double;
      await settle(tester, const Duration(milliseconds: 300));
      expect((ripple().painter! as dynamic).turn, isNot(turn));

      // They stop talking: the rings fade back to nothing.
      transport.speakingLevel = 0;
      await settle(tester, Duration.zero);
      await settle(tester, const Duration(milliseconds: 400));
      expect((ripple().painter! as dynamic).level, 0.0);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      tearDownAll();
    });

    testWidgets('the microphone button shows what it is picking up', (tester) async {
      // Somebody nobody can hear needs to know whether their own phone is
      // hearing them.
      setUpService();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => CallLayer(child: child!),
            home: const Scaffold(body: Text('mapa')),
          ),
        ),
      );
      backend.startCall(service.id, driverId);
      await settle(tester);
      await tester.tap(find.byKey(const Key('call-answer')));
      await settle(tester);

      Size halo() => tester.getSize(
            find.descendant(
              of: find.byKey(const Key('call-own-level')),
              matching: find.byType(Container),
            ),
          );
      final quiet = halo().width;

      transport.ownSpeakingLevel = 0.9;
      await settle(tester, Duration.zero);
      await settle(tester, const Duration(milliseconds: 300));
      expect(halo().width, greaterThan(quiet));

      // Muted, the halo goes: the microphone is off, whatever the room.
      await controller().toggleMute();
      await settle(tester);
      expect(find.byKey(const Key('call-own-level')), findsNothing);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      tearDownAll();
    });

    testWidgets('says so when the other side sends no audio at all', (tester) async {
      setUpService();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => CallLayer(child: child!),
            home: const Scaffold(body: Text('mapa')),
          ),
        ),
      );
      backend.startCall(service.id, driverId);
      await settle(tester);
      await tester.tap(find.byKey(const Key('call-answer')));
      await settle(tester);

      // Their microphone reaches us: nothing to say.
      expect(find.byKey(const Key('call-peer-no-audio')), findsNothing);

      transport.peerAudioArrives = false;
      await settle(tester);
      expect(find.text('No estamos recibiendo su audio'), findsOneWidget);

      await run(tester, controller().hangUp());
      await settle(tester, CallController.endedLinger + const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      tearDownAll();
    });
  });

  group('the call screen', () {
    testWidgets('rings over the app, answers, and hangs up', (tester) async {
      setUpService();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => CallLayer(child: child!),
            home: const Scaffold(body: Text('mapa')),
          ),
        ),
      );
      expect(find.byKey(const Key('call-screen')), findsNothing);

      backend.startCall(service.id, driverId);
      await settle(tester);

      // Over whatever was on screen.
      expect(find.byKey(const Key('call-screen')), findsOneWidget);
      expect(find.text('Llamada entrante'), findsOneWidget);
      expect(find.byKey(const Key('call-answer')), findsOneWidget);
      expect(find.byKey(const Key('call-decline')), findsOneWidget);

      await tester.tap(find.byKey(const Key('call-answer')));
      await settle(tester);

      expect(find.byKey(const Key('call-hangup')), findsOneWidget);
      expect(find.byKey(const Key('call-mute')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('call-status'))).data,
        matches(RegExp(r'^\d\d:\d\d$')),
      );

      await tester.tap(find.byKey(const Key('call-hangup')));
      await settle(tester);
      expect(find.text('Llamada terminada'), findsOneWidget);

      await settle(tester, CallController.endedLinger);
      expect(find.byKey(const Key('call-screen')), findsNothing);
      expect(find.text('mapa'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      tearDownAll();
    });
  });
}
