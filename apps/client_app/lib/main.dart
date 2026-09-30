import 'package:grua_core/grua_core.dart';

import 'app.dart';
import 'firebase_options.dart';

/// Entry point for the customer app.
///
/// All initialization lives in `runGruaApp` so the three products cannot drift
/// in startup order, error capture or locale setup. If Firebase cannot be
/// reached, the app says so on an error screen rather than crashing.
void main() => runGruaApp(
      appKind: AppKind.client,
      builder: ClientApp.new,
      firebaseOptions: DefaultFirebaseOptions.currentPlatform,
    );
