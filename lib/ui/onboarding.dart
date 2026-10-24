import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'i18n.dart';
import 'connection.dart';
import 'files.dart';
import 'theme.dart';
import 'home.dart';
import 'pair.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pages = PageController();
  final _name = TextEditingController();
  final _device = TextEditingController();
  int _page = 0;

  @override
  void initState() {
    super.initState();
    final e = context.engine;
    _device.text = e.me.roster.device(e.id.deviceId)?.name ?? '';
  }

  void _next() {
    setState(() => _page++);
    _pages.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  Future<void> _saveNames() async {
    final e = context.engine;
    if (_name.text.trim().isEmpty) return;
    await e.renameMe(_name.text.trim());
    if (_device.text.trim().isNotEmpty) await e.renameThisDevice(_device.text.trim());
    if (Platform.isAndroid && mounted) await Scope.of(context).host.requestNotificationPermission();
    _next();
  }

  Future<void> _finish(Widget? then) async {
    final nav = Navigator.of(context);
    await context.engine.repo.setSetting('onboarded', '1');
    nav.pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
    if (then != null) nav.push(MaterialPageRoute(builder: (_) => then));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: PageView(
              controller: _pages,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // 1. Name
                ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const SizedBox(height: 24),
                    PopIn(child: Image.asset('assets/icon.png', width: 96, height: 96)),
                    const SizedBox(height: 20),
                    Text(tr('Welcome to DropMate'), style: t.textTheme.headlineLarge, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(
                      tr('Send files to your people over Wi-Fi. No internet, no cloud, no account.'),
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 28),
                    // Your face is what your people see in their "Here now" row.
                    Center(
                      child: ListenableBuilder(
                        listenable: Listenable.merge([context.engine, _name]),
                        builder: (context, _) {
                          final e = context.engine;
                          return InkResponse(
                            radius: 56,
                            onTap: () async {
                              final photo = await pickPhoto();
                              if (photo != null) await e.setMyAvatar(photo);
                            },
                            child: Column(
                              children: [
                                e.me.roster.avatar.isEmpty
                                    ? Container(
                                        width: 92,
                                        height: 92,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: t.colorScheme.surfaceContainerLowest,
                                          border: Border.all(color: t.colorScheme.outlineVariant, width: 2),
                                        ),
                                        child: Icon(Icons.add_a_photo_outlined, size: 32, color: t.colorScheme.primary),
                                      )
                                    : Avatar(
                                        id: e.me.id,
                                        name: _name.text,
                                        photo: e.me.roster.avatar,
                                        online: true,
                                        size: 92,
                                      ),
                                const SizedBox(height: 8),
                                Text(
                                  e.me.roster.avatar.isEmpty ? tr('Add photo') : tr('Change photo'),
                                  style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _name,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(labelText: tr('Your name'), hintText: tr('e.g. Shihab')),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _device,
                      decoration: InputDecoration(labelText: tr('This device'), hintText: tr('e.g. Laptop')),
                    ),
                    const SizedBox(height: 24),
                    ListenableBuilder(
                      listenable: _name,
                      builder: (_, __) => FilledButton(
                        onPressed: _name.text.trim().isEmpty ? null : _saveNames,
                        child: Text(tr('Continue')),
                      ),
                    ),
                  ],
                ),
                // 2. Connection check
                ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    Text(tr('Quick check'), style: t.textTheme.headlineLarge),
                    const SizedBox(height: 8),
                    Text(tr('These make sure files can reach you, even when the app is closed.')),
                    const SizedBox(height: 8),
                    const ChecksView(),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: _next, child: Text(tr('Continue'))),
                  ],
                ),
                // 3. First connection
                ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const SizedBox(height: 32),
                    Text(
                      tr('Who do you want to connect?'),
                      style: t.textTheme.headlineLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.person_add_alt_1),
                        title: Text(tr('Add a person')),
                        subtitle: Text(tr('Your partner, family, a friend')),
                        onTap: () => _finish(const PairScreen()),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.devices_outlined),
                        title: Text(tr('Link another of my devices')),
                        subtitle: Text(tr('Your other phone or laptop. History and contacts sync.')),
                        onTap: () => _finish(const PairScreen(link: true)),
                      ),
                    ),
                    TextButton(onPressed: () => _finish(null), child: Text(tr('Later'))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
