import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

/// The media half of a call: take the microphone (and the camera, for a video
/// call), connect, talk, hang up.
///
/// An interface rather than LiveKit directly because two things cannot open a
/// real media session — a widget test has no LiveKit server, microphone or
/// camera — and it still needs the whole call flow to run.
/// [SilentVoiceTransport] stands in there.
abstract class VoiceTransport {
  /// Takes the microphone, and the camera when [video], asking for permission
  /// if it has to.
  ///
  /// Called *before* anybody is rung: a person who cannot talk should find out
  /// before the other phone starts ringing, not after it has been answered.
  Future<void> prepare({bool video = false});

  /// Joins the call's room and starts sending what [prepare] took.
  Future<void> connect({required String url, required String token});

  /// Fires when the other person is in the room and can be heard.
  Stream<void> get peerJoined;

  /// Fires when the other person leaves the room, or the connection is lost.
  Stream<void> get peerLeft;

  Future<void> setMuted({required bool muted});

  /// Loudspeaker rather than earpiece. A no-op where there is no earpiece.
  Future<void> setSpeaker({required bool on});

  bool get canSwitchSpeaker;

  /// This person's own camera, for the preview. Null on a voice call, and
  /// while the camera is off.
  ValueListenable<lk.VideoTrack?> get localVideo;

  /// The other person's camera. Null until it arrives, and while they have it
  /// off.
  ValueListenable<lk.VideoTrack?> get remoteVideo;

  /// How loudly the other person is speaking right now, from 0 to 1.
  ///
  /// Drives the ripple around their avatar: on a voice call, or a video call
  /// with their camera off, it is the only sign that the line is alive and
  /// that they are the one talking.
  ValueListenable<double> get peerAudioLevel;

  /// How loudly this person is speaking, from 0 to 1. Shown on their own
  /// microphone button, so somebody who is not being heard can see whether
  /// their microphone is picking anything up at all.
  ValueListenable<double> get ownAudioLevel;

  /// Whether the other person's microphone is reaching us: their audio track
  /// is subscribed and not muted. False means silence is theirs, not ours.
  ValueListenable<bool> get peerHasAudio;

  /// Stops or restarts sending the picture, keeping the call.
  Future<void> setCameraOn({required bool on});

  /// Front to back camera and back again.
  Future<void> switchCamera();

  /// Leaves the room and gives the microphone and camera back.
  Future<void> disconnect();
}

/// Makes the media side of a call — a real one by default, a silent one in
/// tests.
final voiceTransportFactoryProvider = Provider<VoiceTransport Function()>(
  (ref) => LiveKitVoiceTransport.new,
);

/// What stopped the call's audio or picture, in words the person can act on.
enum CallAudioProblem {
  /// Permission refused, dismissed, or blocked for this site.
  permission(
    'Permite el uso del micrófono para llamar. En el navegador, toca el ícono '
    'del candado junto a la dirección y activa el micrófono.',
    video:
        'Permite el uso de la cámara y el micrófono para la videollamada. En el '
        'navegador, toca el ícono del candado junto a la dirección y actívalos.',
  ),

  /// No microphone on this device, or none the browser can see.
  noMicrophone(
    'No encontramos un micrófono en este dispositivo.',
    video: 'No encontramos una cámara o un micrófono en este dispositivo.',
  ),

  /// Allowed, but the system would not open it: another program holding it,
  /// the operating system's own privacy switch, or a device that failed.
  microphoneBusy(
    'No pudimos abrir el micrófono. Puede que otra aplicación lo esté usando '
    'o que el sistema lo tenga bloqueado.',
    video:
        'No pudimos abrir la cámara o el micrófono. Puede que otra aplicación '
        'los esté usando o que el sistema los tenga bloqueados.',
  ),

  /// The page is not on HTTPS or localhost, where browsers refuse microphones.
  insecurePage(
    'El navegador solo permite el micrófono en páginas seguras (https).',
    video: 'El navegador solo permite la cámara en páginas seguras (https).',
  ),

  /// Could not reach the call server.
  connection('No pudimos conectar la llamada. Revisa tu conexión.'),

  /// Anything else.
  unknown('No pudimos iniciar el audio de la llamada. Intenta de nuevo.');

  const CallAudioProblem(this.message, {String? video}) : _videoMessage = video;

  /// The words for a voice call.
  final String message;
  final String? _videoMessage;

  /// The words for this kind of call: a video call that could not open the
  /// camera must not only blame the microphone.
  String messageFor({required bool video}) =>
      video ? (_videoMessage ?? message) : message;

  /// Reads what went wrong from the error the platform actually threw.
  ///
  /// There is no shared type to switch on: the web hands back a browser
  /// `DOMException` whose name is only in its text, the phones a LiveKit
  /// exception wrapping a platform one. So it is read by name — which is what
  /// the old catch-all did not do, and why every failure used to be blamed on
  /// the microphone.
  static CallAudioProblem of(Object error) {
    final text = error.toString();
    bool has(String needle) => text.toLowerCase().contains(needle.toLowerCase());

    if (has('NotAllowedError') ||
        has('PermissionDenied') ||
        has('Permission denied') ||
        has('permission is not granted')) {
      return CallAudioProblem.permission;
    }
    if (has('NotFoundError') || has('device not found') || has('OverconstrainedError')) {
      return CallAudioProblem.noMicrophone;
    }
    if (has('NotReadableError') ||
        has('Could not start audio source') ||
        has('Could not start video source') ||
        has('TrackStartError')) {
      return CallAudioProblem.microphoneBusy;
    }
    if (has('SecurityError') || has('mediaDevices') || has('getUserMedia is not')) {
      return CallAudioProblem.insecurePage;
    }
    if (error is lk.ConnectException ||
        error is lk.MediaConnectException ||
        error is TimeoutException ||
        has('websocket') ||
        has('could not connect')) {
      return CallAudioProblem.connection;
    }
    if (error is lk.TrackCreateException) return CallAudioProblem.permission;
    return CallAudioProblem.unknown;
  }
}

/// A real call, over LiveKit.
class LiveKitVoiceTransport implements VoiceTransport {
  lk.Room? _room;
  lk.LocalAudioTrack? _mic;
  lk.LocalVideoTrack? _camera;
  lk.EventsListener<lk.RoomEvent>? _listener;
  final _joined = StreamController<void>.broadcast();
  final _left = StreamController<void>.broadcast();
  final _localVideo = ValueNotifier<lk.VideoTrack?>(null);
  final _remoteVideo = ValueNotifier<lk.VideoTrack?>(null);
  final _peerAudioLevel = ValueNotifier<double>(0);
  final _ownAudioLevel = ValueNotifier<double>(0);
  final _peerHasAudio = ValueNotifier<bool>(false);
  lk.CameraPosition _position = lk.CameraPosition.front;

  static const _capture = lk.AudioCaptureOptions(
    echoCancellation: true,
    noiseSuppression: true,
    autoGainControl: true,
  );

  @override
  Stream<void> get peerJoined => _joined.stream;

  @override
  Stream<void> get peerLeft => _left.stream;

  @override
  bool get canSwitchSpeaker => lk.AudioManager.instance.canSwitchSpeakerphone;

  @override
  ValueListenable<lk.VideoTrack?> get localVideo => _localVideo;

  @override
  ValueListenable<lk.VideoTrack?> get remoteVideo => _remoteVideo;

  @override
  ValueListenable<double> get peerAudioLevel => _peerAudioLevel;

  @override
  ValueListenable<double> get ownAudioLevel => _ownAudioLevel;

  @override
  ValueListenable<bool> get peerHasAudio => _peerHasAudio;

  @override
  Future<void> prepare({bool video = false}) async {
    _mic ??= await lk.LocalAudioTrack.create(_capture);
    if (video && _camera == null) {
      // 540p: plenty for a face or a dented bumper on a phone, and light on a
      // roadside mobile connection.
      final camera = await lk.LocalVideoTrack.createCameraTrack(
        lk.CameraCaptureOptions(
          cameraPosition: _position,
          params: lk.VideoParametersPresets.h540_169,
        ),
      );
      _camera = camera;
      _localVideo.value = camera;
    }
  }

  @override
  Future<void> connect({required String url, required String token}) async {
    final video = _camera != null;
    final room = lk.Room(
      roomOptions: lk.RoomOptions(
        // Both exist to save video bandwidth, so only a video call wants them.
        adaptiveStream: video,
        dynacast: video,
        defaultAudioCaptureOptions: _capture,
      ),
    );
    _room = room;

    _listener = room.createListener()
      ..on<lk.ParticipantConnectedEvent>((_) => _joined.add(null))
      ..on<lk.ParticipantDisconnectedEvent>((_) {
        _remoteVideo.value = null;
        _peerAudioLevel.value = 0;
        _left.add(null);
      })
      // LiveKit reports who is speaking and how loudly, ordered loudest
      // first, and zeroes the level when they stop. Only the other person
      // counts: our own voice is not news to us.
      ..on<lk.ActiveSpeakersChangedEvent>((event) {
        final peer = event.speakers.whereType<lk.RemoteParticipant>().firstOrNull;
        _peerAudioLevel.value = (peer?.audioLevel ?? 0).clamp(0.0, 1.0);
        final me = event.speakers.whereType<lk.LocalParticipant>().firstOrNull;
        _ownAudioLevel.value = (me?.audioLevel ?? 0).clamp(0.0, 1.0);
      })
      // Lost for good — the other side will not hear anything more either.
      ..on<lk.RoomDisconnectedEvent>((_) => _left.add(null))
      ..on<lk.TrackSubscribedEvent>((event) {
        final track = event.track;
        if (track is lk.VideoTrack) _remoteVideo.value = track;
        if (track is lk.AudioTrack) _peerHasAudio.value = !event.publication.muted;
      })
      ..on<lk.TrackUnsubscribedEvent>((event) {
        if (identical(event.track, _remoteVideo.value)) _remoteVideo.value = null;
        if (event.track is lk.AudioTrack) _peerHasAudio.value = false;
      })
      // The other person switched their camera off, or back on.
      ..on<lk.TrackMutedEvent>((event) {
        if (event.participant is! lk.RemoteParticipant) return;
        if (event.publication.kind == lk.TrackType.VIDEO) _remoteVideo.value = null;
        if (event.publication.kind == lk.TrackType.AUDIO) {
          _peerAudioLevel.value = 0;
          _peerHasAudio.value = false;
        }
      })
      ..on<lk.TrackUnmutedEvent>((event) {
        if (event.participant is! lk.RemoteParticipant) return;
        final track = event.publication.track;
        if (track is lk.VideoTrack) _remoteVideo.value = track;
        if (track is lk.AudioTrack) _peerHasAudio.value = true;
      });

    await room.connect(url, token);

    final mic = _mic ?? await lk.LocalAudioTrack.create(_capture);
    _mic = mic;
    await room.localParticipant?.publishAudioTrack(mic);

    final camera = _camera;
    if (camera != null) await room.localParticipant?.publishVideoTrack(camera);

    // Browsers refuse to play audio a page starts on its own. Harmless when
    // they refuse: LiveKit reports it rather than throwing.
    if (kIsWeb) await room.startAudio();

    // Already there: the caller joined first and has been waiting, and may
    // already be sending their picture.
    if (room.remoteParticipants.isNotEmpty) {
      for (final participant in room.remoteParticipants.values) {
        for (final publication in participant.videoTrackPublications) {
          final track = publication.track;
          if (track != null && !publication.muted) _remoteVideo.value = track;
        }
        for (final publication in participant.audioTrackPublications) {
          if (publication.track != null && !publication.muted) {
            _peerHasAudio.value = true;
          }
        }
      }
      _joined.add(null);
    }
  }

  @override
  Future<void> setMuted({required bool muted}) async {
    final mic = _mic;
    if (mic == null) return;
    if (muted) {
      await mic.mute(stopOnMute: false);
    } else {
      await mic.unmute(stopOnMute: false);
    }
  }

  @override
  Future<void> setSpeaker({required bool on}) async {
    if (!canSwitchSpeaker) return;
    await lk.AudioManager.instance.setSpeakerOutputPreferred(on);
  }

  @override
  Future<void> setCameraOn({required bool on}) async {
    final camera = _camera;
    if (camera == null) return;
    if (on) {
      await camera.unmute();
      _localVideo.value = camera;
    } else {
      // Stopped, not just hidden: the light on the phone goes off too.
      _localVideo.value = null;
      await camera.mute();
    }
  }

  @override
  Future<void> switchCamera() async {
    final camera = _camera;
    if (camera == null) return;
    _position = _position == lk.CameraPosition.front
        ? lk.CameraPosition.back
        : lk.CameraPosition.front;
    await camera.setCameraPosition(_position);
  }

  @override
  Future<void> disconnect() async {
    final room = _room;
    final mic = _mic;
    final camera = _camera;
    _room = null;
    _mic = null;
    _camera = null;
    _localVideo.value = null;
    _remoteVideo.value = null;
    _peerAudioLevel.value = 0;
    _ownAudioLevel.value = 0;
    _peerHasAudio.value = false;
    await _listener?.dispose();
    _listener = null;
    if (room != null) {
      await room.disconnect();
      await room.dispose();
    }
    // Given back even when the call never connected — cancelled during the
    // permission prompt, refused by the server — or the browser keeps showing
    // the microphone and camera as in use.
    if (mic != null) {
      await mic.stop();
      await mic.dispose();
    }
    if (camera != null) {
      await camera.stop();
      await camera.dispose();
    }
  }
}

/// A call with no audio or picture, for tests.
///
/// Reports the other person as joined as soon as it connects: the ringing and
/// answering are what the rest of the call flow is waiting on, and those come
/// from the call document, not from here.
class SilentVoiceTransport implements VoiceTransport {
  SilentVoiceTransport({this.prepareError});

  /// For tests: what [prepare] throws, standing in for a refused microphone.
  final Exception? prepareError;

  final _joined = StreamController<void>.broadcast();
  final _left = StreamController<void>.broadcast();
  final _noVideo = ValueNotifier<lk.VideoTrack?>(null);
  final _level = ValueNotifier<double>(0);
  final _ownLevel = ValueNotifier<double>(0);
  final _hasPeerAudio = ValueNotifier<bool>(true);

  bool prepared = false;
  bool preparedVideo = false;
  bool connected = false;
  bool muted = false;
  bool speaker = false;
  bool cameraOn = false;
  int cameraSwitches = 0;

  @override
  Stream<void> get peerJoined => _joined.stream;

  @override
  Stream<void> get peerLeft => _left.stream;

  @override
  bool get canSwitchSpeaker => true;

  @override
  ValueListenable<lk.VideoTrack?> get localVideo => _noVideo;

  @override
  ValueListenable<lk.VideoTrack?> get remoteVideo => _noVideo;

  @override
  ValueListenable<double> get peerAudioLevel => _level;

  @override
  ValueListenable<double> get ownAudioLevel => _ownLevel;

  @override
  ValueListenable<bool> get peerHasAudio => _hasPeerAudio;

  /// For tests: how loudly the other person is talking, or 0 for silence.
  double get speakingLevel => _level.value;

  set speakingLevel(double level) => _level.value = level;

  /// For tests: how loudly this person is talking.
  double get ownSpeakingLevel => _ownLevel.value;

  set ownSpeakingLevel(double level) => _ownLevel.value = level;

  /// For tests: whether the other side's microphone reaches us at all.
  bool get peerAudioArrives => _hasPeerAudio.value;

  set peerAudioArrives(bool arrives) => _hasPeerAudio.value = arrives;

  @override
  Future<void> prepare({bool video = false}) async {
    final error = prepareError;
    if (error != null) throw error;
    prepared = true;
    preparedVideo = video;
    cameraOn = video;
  }

  @override
  Future<void> connect({required String url, required String token}) async {
    connected = true;
    scheduleMicrotask(() => _joined.add(null));
  }

  /// For tests: the other person drops.
  void simulatePeerLeft() => _left.add(null);

  @override
  Future<void> setMuted({required bool muted}) async => this.muted = muted;

  @override
  Future<void> setSpeaker({required bool on}) async => speaker = on;

  @override
  Future<void> setCameraOn({required bool on}) async => cameraOn = on;

  @override
  Future<void> switchCamera() async => cameraSwitches++;

  @override
  Future<void> disconnect() async {
    connected = false;
    prepared = false;
    preparedVideo = false;
    cameraOn = false;
    _level.value = 0;
    _ownLevel.value = 0;
  }
}
