import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';

import '../platform/native.dart';
import 'app.dart';
import 'i18n.dart';
import 'connection.dart';
import 'files.dart';
import 'pair.dart';
import 'person.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _startup;
  String? _download;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) launchAtStartup.isEnabled().then((v) => mounted ? setState(() => _startup = v) : null);
    Scope.of(context).host.downloadDir().then((d) => mounted ? setState(() => _download = d) : null);
  }

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final scope = Scope.of(context);
    final t = Theme.of(context);
    Widget header(String s) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 6),
      child: Text(s, style: t.textTheme.headlineSmall),
    );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Settings'))),
      body: ListenableBuilder(
        listenable: e,
        builder: (context, _) {
          final thisDevice = e.me.roster.device(e.id.deviceId);
          return ListView(
            // Readable column on wide windows.
            padding: EdgeInsets.symmetric(horizontal: ((MediaQuery.sizeOf(context).width - 680) / 2).clamp(0, 9999)),
            children: [
              const ProfileHeader(),
              header(tr('You')),
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(tr('Your name')),
                subtitle: Text(e.me.roster.name),
                onTap: () async {
                  final v = await prompt(context, tr('Your name'), e.me.roster.name);
                  if (v != null && v.isNotEmpty) await e.renameMe(v);
                },
              ),
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(tr('This device')),
                subtitle: Text(thisDevice?.name ?? ''),
                onTap: () async {
                  final v = await prompt(context, tr('This device'), thisDevice?.name ?? '');
                  if (v != null && v.isNotEmpty) await e.renameThisDevice(v);
                },
              ),
              header(tr('My devices')),
              for (final d in e.me.roster.devices.where((d) => d.id != e.id.deviceId))
                ListTile(
                  leading: Icon(d.platform == 'windows' ? Icons.laptop_windows : Icons.smartphone),
                  title: Text(d.name),
                  subtitle: Text(e.deviceOnline(d.id) ? tr('Online') : tr('Offline')),
                  trailing: IconButton(
                    tooltip: tr('Remove'),
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () async {
                      if (await sure(
                        context,
                        'Remove ${d.name}?',
                        'It will no longer receive your messages or files. Your people will stop trusting it too.',
                      )) {
                        await e.removeMyDevice(d.id);
                      }
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add_link),
                title: Text(tr('Link a device')),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PairScreen(link: true))),
              ),
              header(tr('Files')),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text(tr('Download folder')),
                subtitle: Text(_download ?? ''),
                onTap: () async {
                  final d = await pickDirectory(context);
                  if (d == null) return;
                  await e.repo.setSetting('download_dir', d);
                  Native.setDownloadDirOverride(d);
                  setState(() => _download = d);
                },
              ),
              header(tr('App')),
              ListTile(
                leading: const Icon(Icons.dark_mode_outlined),
                title: Text(tr('Theme')),
                trailing: SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: ThemeMode.system, label: Text(tr('Auto'))),
                    ButtonSegment(value: ThemeMode.light, label: Text(tr('Light'))),
                    ButtonSegment(value: ThemeMode.dark, label: Text(tr('Dark'))),
                  ],
                  selected: {scope.theme.value},
                  onSelectionChanged: (s) {
                    scope.theme.value = s.first;
                    e.repo.setSetting('theme', s.first.name);
                    setState(() {});
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.translate),
                title: Text(tr('Language')),
                trailing: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'en', label: Text('English')),
                    ButtonSegment(value: 'bn', label: Text('বাংলা')),
                  ],
                  selected: {language.value},
                  onSelectionChanged: (s) {
                    language.value = s.first;
                    e.repo.setSetting('language', s.first);
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text(tr('Speed limit')),
                subtitle: Text(tr('Keeps your Wi-Fi usable for others while sending')),
                trailing: DropdownButton<int>(
                  value: e.speedLimit,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(value: 0, child: Text(tr('No limit'))),
                    for (final mb in const [2, 5, 10, 20, 50])
                      DropdownMenuItem(value: mb << 20, child: Text('$mb MB/s')),
                  ],
                  onChanged: (v) => e.setSpeedLimit(v ?? 0),
                ),
              ),
              if (Platform.isWindows && _startup != null)
                SwitchListTile(
                  secondary: const Icon(Icons.power_settings_new),
                  title: Text(tr('Start with Windows')),
                  subtitle: Text(tr('Runs in the tray so files reach you any time')),
                  value: _startup!,
                  onChanged: (v) async {
                    v ? await launchAtStartup.enable() : await launchAtStartup.disable();
                    setState(() => _startup = v);
                  },
                ),
              header(tr('History')),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: Text(tr('Export history')),
                onTap: () async {
                  final dir = await scope.host.downloadDir();
                  Directory(dir).createSync(recursive: true);
                  final path =
                      '$dir${Platform.pathSeparator}dropmate-history-${DateTime.now().millisecondsSinceEpoch}.json';
                  File(path).writeAsStringSync(await e.exportHistory());
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(tr('Saved to {path}', {'path': path}))));
                  }
                },
              ),
              ListTile(
                leading: Icon(Icons.link_off, color: t.colorScheme.error),
                title: Text(tr('Unpair everyone'), style: TextStyle(color: t.colorScheme.error)),
                onTap: () async {
                  if (await sure(context, tr('Unpair everyone?'), tr('You will need to pair again to send files'))) {
                    await e.unpairAll();
                  }
                },
              ),
              header(tr('Connection check')),
              const ChecksView(),
              header(tr('About')),
              ListTile(
                leading: const Icon(Icons.fingerprint),
                title: Text(tr('Device ID')),
                subtitle: SelectableText(e.id.deviceId),
              ),
              ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: Text(tr('Listening on')),
                subtitle: Text(
                  'Port ${e.server.port} · ${e.contacts.length} people · ${e.me.roster.devices.length} of your devices',
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr('DropMate never sends anything outside your Wi-Fi. No account, no cloud, no analytics.'),
                  style: t.textTheme.bodySmall,
                ),
              ),
              const Center(child: Wordmark(size: 18)),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

/// Your face as your people see it; tap it to change the photo (synced to all your devices and contacts).
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final e = context.engine;
    final t = Theme.of(context);
    final me = e.me.roster;
    final thisDevice = me.device(e.id.deviceId);
    Future<void> change() async {
      final photo = await pickPhoto();
      if (photo != null) await e.setMyAvatar(photo);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        children: [
          Tooltip(
            message: tr('Change photo'),
            child: InkResponse(
              onTap: change,
              radius: 64,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Avatar(id: e.me.id, name: me.name, photo: me.avatar, online: true, size: 116),
                  Positioned(
                    right: 0,
                    bottom: 2,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: t.colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: t.colorScheme.surface, width: 3),
                      ),
                      child: const Icon(Icons.photo_camera_rounded, size: 18, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(me.name, style: t.textTheme.headlineLarge, textAlign: TextAlign.center),
          const SizedBox(height: 2),
          Text(thisDevice?.name ?? '', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              ActionChip(
                avatar: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text(me.avatar.isEmpty ? tr('Add photo') : tr('Change photo')),
                onPressed: change,
              ),
              if (me.avatar.isNotEmpty)
                ActionChip(
                  avatar: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: Text(tr('Remove photo')),
                  onPressed: () => e.setMyAvatar(''),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
