import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/network_info.dart';
import 'data/prefs_repository.dart';
import 'state/session_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await PrefsRepository.open();
  // 一打开就摸一次局域网，逼 iOS 弹「本地网络」授权框；不 await，不挡启动。
  unawaited(triggerLocalNetworkPrompt());
  runApp(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs)],
      child: const VaultApp(),
    ),
  );
}
