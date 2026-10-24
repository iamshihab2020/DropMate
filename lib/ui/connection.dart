import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/native.dart';
import '../services/discovery.dart';
import 'i18n.dart';

const _ruleName = 'DropMate (local network)';

/// Our inbound rule exists and Windows hasn't recorded a Block rule for the app (from a declined prompt).
Future<bool> firewallReady() async {
  final exe = Platform.resolvedExecutable.replaceAll("'", "''");
  final r = await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    "\$a = Get-NetFirewallRule -DisplayName '$_ruleName' -ErrorAction SilentlyContinue | Where-Object Enabled -eq True; "
        "\$b = Get-NetFirewallApplicationFilter -Program '$exe' -ErrorAction SilentlyContinue | Get-NetFirewallRule | "
        "Where-Object { \$_.Action -eq 'Block' -and \$_.Direction -eq 'Inbound' -and \$_.Enabled -eq 'True' }; "
        "if (\$a -and -not \$b) { 'ok' } else { 'no' }",
  ]);
  return '${r.stdout}'.trim() == 'ok';
}

/// One admin prompt: allow inbound on Private and Public profiles, but only from the local subnet,
/// and drop Block rules Windows created if its own prompt was declined (PRD §14.2).
Future<void> allowThroughFirewall() async {
  final exe = Platform.resolvedExecutable.replaceAll("'", "''");
  // A script file avoids nesting quotes through Start-Process.
  final ps1 = File('${Directory.systemTemp.path}${Platform.pathSeparator}dropmate-firewall.ps1')
    ..writeAsStringSync(
      "Get-NetFirewallApplicationFilter -Program '$exe' -ErrorAction SilentlyContinue | Get-NetFirewallRule | "
      "Where-Object Action -eq 'Block' | Remove-NetFirewallRule\r\n"
      "Remove-NetFirewallRule -DisplayName '$_ruleName' -ErrorAction SilentlyContinue\r\n"
      "New-NetFirewallRule -DisplayName '$_ruleName' -Direction Inbound -Action Allow -Program '$exe' "
      "-Profile Private,Public -RemoteAddress LocalSubnet | Out-Null\r\n",
    );
  await Process.run('powershell', [
    '-NoProfile',
    '-Command',
    "Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden "
        "-ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','${ps1.path}'",
  ]);
}

class Check {
  final String title;
  final bool ok;
  final String detail;
  final String? fixLabel;
  final Future<void> Function()? fix;
  Check(this.title, this.ok, this.detail, {this.fixLabel, this.fix});
}

/// First-run and Settings "Connection check" (PRD §7.1).
Future<List<Check>> runChecks() async {
  final out = <Check>[];
  final ips = await localIps();
  final lan = ips.where((ip) => ip.startsWith('192.168.') || ip.startsWith('10.') || ip.startsWith('172.')).toList();
  out.add(
    Check(
      tr('Connected to Wi-Fi'),
      lan.isNotEmpty,
      lan.isNotEmpty ? tr('Your address: {ip}', {'ip': lan.first}) : tr('Connect to the same Wi-Fi as your people.'),
    ),
  );

  bool vpn = false;
  if (Platform.isAndroid) {
    vpn = await Native.vpnActive();
  } else {
    for (final i in await NetworkInterface.list()) {
      final n = i.name.toLowerCase();
      if (n.contains('vpn') || n.contains('wireguard') || n.contains('tap-') || n.contains('tun')) vpn = true;
    }
  }
  out.add(
    Check(tr('No VPN'), !vpn, vpn ? tr('A VPN can block devices on your Wi-Fi from reaching each other.') : tr('Good')),
  );

  if (Platform.isWindows) {
    final ok = await firewallReady();
    out.add(
      Check(
        tr('Firewall allows DropMate'),
        ok,
        ok
            ? tr('Good')
            : tr(
                'Windows blocks incoming files until DropMate is allowed. Works on Public and Private Wi-Fi, local network only.',
              ),
        fixLabel: ok ? null : tr('Allow'),
        fix: ok ? null : allowThroughFirewall,
      ),
    );
  }

  if (Platform.isAndroid) {
    final ignoring = await Native.isIgnoringBatteryOptimizations();
    final brand = (await Native.manufacturer()).toLowerCase();
    final extra = const {'xiaomi', 'oppo', 'vivo', 'realme', 'samsung', 'oneplus', 'huawei'}.contains(brand)
        ? ' ${tr('On {brand} phones also allow "Autostart" / "Run in background" for DropMate.', {'brand': '${brand[0].toUpperCase()}${brand.substring(1)}'})}'
        : '';
    out.add(
      Check(
        tr('Allowed to run in background'),
        ignoring,
        ignoring
            ? '${tr('Good')}$extra'
            : '${tr("Without this, the phone may stop DropMate and you'll miss files.")}$extra',
        fixLabel: ignoring ? null : tr('Allow'),
        fix: ignoring ? null : Native.requestIgnoreBatteryOptimizations,
      ),
    );
    if (await Native.needsStoragePermission()) {
      out.add(
        Check(
          tr('Storage access'),
          false,
          tr('Needed on this Android version to save into Downloads.'),
          fixLabel: tr('Allow'),
          fix: () async => Native.requestStoragePermission(),
        ),
      );
    }
  }
  return out;
}

class ChecksView extends StatefulWidget {
  const ChecksView({super.key});

  @override
  State<ChecksView> createState() => _ChecksViewState();
}

class _ChecksViewState extends State<ChecksView> {
  late Future<List<Check>> _f = runChecks();

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _f,
    builder: (context, snap) {
      if (!snap.hasData) {
        return const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Column(
        children: [
          for (final c in snap.data!)
            ListTile(
              leading: Icon(
                c.ok ? Icons.check_circle : Icons.error_outline,
                color: c.ok ? const Color(0xFF2EB872) : Theme.of(context).colorScheme.error,
              ),
              title: Text(c.title),
              subtitle: Text(c.detail),
              trailing: c.fix == null
                  ? null
                  : TextButton(
                      onPressed: () async {
                        await c.fix!();
                        setState(() => _f = runChecks());
                      },
                      child: Text(c.fixLabel ?? tr('Fix')),
                    ),
            ),
          TextButton.icon(
            onPressed: () => setState(() => _f = runChecks()),
            icon: const Icon(Icons.refresh),
            label: Text(tr('Check again')),
          ),
        ],
      );
    },
  );
}
