import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/host_impl.dart';
import '../platform/native.dart';
import '../services/engine.dart';
import '../services/sources.dart';
import '../services/transfers.dart';
import 'accept_sheet.dart';
import 'chat.dart';
import 'home.dart';
import 'i18n.dart';
import 'onboarding.dart';
import 'share_target.dart';
import 'theme.dart';

class Scope extends InheritedWidget {
  final Engine engine;
  final AppHost host;
  final ValueNotifier<ThemeMode> theme;
  const Scope({super.key, required this.engine, required this.host, required this.theme, required super.child});

  // Never changes after start, so no dependency is registered (safe in initState).
  static Scope of(BuildContext c) => c.getInheritedWidgetOfExactType<Scope>()!;
  @override
  bool updateShouldNotify(Scope old) => false;
}

extension Ctx on BuildContext {
  Engine get engine => Scope.of(this).engine;
}

final navKey = GlobalKey<NavigatorState>();

class DropMateApp extends StatefulWidget {
  final Engine engine;
  final AppHost host;
  final bool onboarded;
  final Stream<List<Source>> incomingShares;
  const DropMateApp({
    super.key,
    required this.engine,
    required this.host,
    required this.onboarded,
    required this.incomingShares,
  });

  @override
  State<DropMateApp> createState() => _DropMateAppState();
}

class _DropMateAppState extends State<DropMateApp> with WidgetsBindingObserver {
  final theme = ValueNotifier(ThemeMode.system);
  final _subs = <StreamSubscription>[];
  final _open = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.engine.repo.setting('language').then((l) => language.value = l ?? 'en');
    widget.engine.repo.setting('language').then((l) => language.value = l ?? 'en');
    language.addListener(_rebuildEverything);
    widget.engine.repo.setting('theme').then((t) {
      theme.value = ThemeMode.values.firstWhere((m) => m.name == t, orElse: () => ThemeMode.system);
    });
    widget.host.onDecision = (tid, ok) => widget.engine.transfers.decide(tid, ok);
    widget.host.onCancel = (tid) => widget.engine.transfers.cancel(tid);
    Native.onBuzzStopped = widget.engine.stopBuzz;
    widget.engine.buzzing.addListener(() {
      if (widget.engine.buzzing.value != null && Platform.isWindows) {
        windowManager.show();
        windowManager.focus();
      }
    });
    widget.host.onOpen = (personId) {
      final nav = navKey.currentState;
      if (nav == null) return;
      if (personId != null) nav.push(MaterialPageRoute(builder: (_) => ChatScreen(personId: personId)));
    };
    _subs.add(widget.engine.transfers.incoming.listen(_showIncoming));
    _subs.add(
      widget.incomingShares.listen((files) {
        navKey.currentState?.push(MaterialPageRoute(builder: (_) => ShareTargetScreen(files: files)));
      }),
    );
  }

  void _showIncoming(Incoming inc) {
    final ctx = navKey.currentContext;
    if (ctx == null || !_open.add(inc.transferId)) return;
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AcceptSheet(inc: inc),
    ).whenComplete(() => _open.remove(inc.transferId));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    final visible = s == AppLifecycleState.resumed;
    widget.host.appVisible = visible;
    widget.engine.setForeground(visible);
    final open = widget.host.openConversation;
    if (visible && open != null) widget.engine.markRead(open); // sends "seen" for what arrived while away
    if (visible && Platform.isAndroid) Native.startService();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// tr() isn't an InheritedWidget, so a language change marks the whole tree dirty.
  void _rebuildEverything() {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }

  @override
  Widget build(BuildContext context) => Scope(
    engine: widget.engine,
    host: widget.host,
    theme: theme,
    child: ValueListenableBuilder(
      valueListenable: theme,
      builder: (_, mode, __) => MaterialApp(
        navigatorKey: navKey,
        title: 'DropMate',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        builder: (context, child) => Stack(
          children: [
            child!,
            ValueListenableBuilder(
              valueListenable: widget.engine.buzzing,
              builder: (_, who, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: who == null ? const SizedBox.shrink() : _BuzzCard(who: who, onStop: widget.engine.stopBuzz),
              ),
            ),
          ],
        ),
        home: widget.onboarded ? const HomeScreen() : const OnboardingScreen(),
      ),
    ),
  );
}

/// Full-screen "Mom is buzzing you" while this device rings.
class _BuzzCard extends StatelessWidget {
  final ({String id, String name, String photo}) who;
  final VoidCallback onStop;
  const _BuzzCard({required this.who, required this.onStop});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: Brand.deepwater.withValues(alpha: 0.94),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Avatar(id: who.id, name: who.name, photo: who.photo, online: true, pulse: true, size: 132),
                const SizedBox(height: 32),
                Text(
                  tr('{name} is buzzing you', {'name': who.name}),
                  textAlign: TextAlign.center,
                  style: t.textTheme.headlineMedium?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 8),
                Text(
                  tr('Found it? Tap Stop.'),
                  style: t.textTheme.bodyLarge?.copyWith(color: Colors.white70),
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  autofocus: true,
                  style: FilledButton.styleFrom(
                    backgroundColor: Brand.signal,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(200, 56),
                  ),
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(tr('Stop')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
