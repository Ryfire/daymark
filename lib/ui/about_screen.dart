import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// About page content — edit these values to update what users see.
/// Links open in the browser; the app itself stays offline.
class _SupportLink {
  const _SupportLink(this.label, this.url, {required this.icon, this.subtitle});
  final String label;
  final String url;
  final IconData icon;
  final String? subtitle;
}

const String _aboutMessage =
    'Daymark is the companion to JotLock: jot fast on the lock screen, '
    'then let Daymark turn your exports into answers — grounded ask-over-'
    'notes, quick rewrites, and day-grouped reading. It runs entirely on '
    'your device and you bring the LLM. If it makes your jottings useful, '
    'there are easy ways to say thanks — free ones, or over coffee. '
    'Thank you!';

const List<_SupportLink> _supportLinks = [
  _SupportLink(
    'Star Daymark on GitHub',
    'https://github.com/Ryfire/daymark',
    icon: Icons.star_border,
    subtitle: 'One tap — helps others find the app',
  ),
  _SupportLink(
    'Say how it goes',
    'https://github.com/Ryfire/daymark/discussions',
    icon: Icons.forum_outlined,
    subtitle: 'Does it fit your workflow? Reports wanted either way',
  ),
  _SupportLink(
    'Buy me a coffee',
    'https://buymeacoffee.com/JameyR',
    icon: Icons.local_cafe_outlined,
    subtitle: 'Optional — keeps it free, open source, and ad-free',
  ),
];

const String _sourceUrl = 'https://github.com/Ryfire/daymark';

const String _jotlockUrl = 'https://github.com/Ryfire/jotlock';

/// In-app About page: developer note, support links, source code, version.
/// Mirrors JotLock's About page; Daymark data stays on the device and the
/// LLM endpoint is the only thing it talks to.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final version = await ref.read(jotlockSenderProvider).getVersionName();
    if (!mounted) return;
    setState(() => _version = version);
  }

  Future<void> _open(String url) async {
    await ref.read(jotlockSenderProvider).openUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About Daymark')),
      // SafeArea bottom: the footer text otherwise ends up under the
      // system navigation bar on phones.
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: Column(
                children: [
                  Image.asset(
                    'assets/images/daymark_icon.png',
                    key: const Key('about-daymark-mark'),
                    width: 96,
                    height: 96,
                    filterQuality: FilterQuality.medium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Daymark',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (_version.isNotEmpty)
                    Text(
                      'Version $_version',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(_aboutMessage, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            const Divider(),
            for (final link in _supportLinks)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(link.icon),
                title: Text(link.label),
                subtitle: link.subtitle != null ? Text(link.subtitle!) : null,
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _open(link.url),
              ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.code),
              title: const Text('Source code on GitHub'),
              subtitle: const Text('Inspect every line'),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => _open(_sourceUrl),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: const Text('Get JotLock'),
              subtitle: const Text(
                'The capture half — lock-screen note taking',
              ),
              trailing: const Icon(Icons.open_in_new, size: 18),
              onTap: () => _open(_jotlockUrl),
            ),
            const Divider(),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: const Text('Open source licenses'),
              onTap: () => showLicensePage(context: context),
            ),
            const SizedBox(height: 8),
            Text(
              'Notes live in a local database on your device. Nothing is '
              'synced; only the text you ask or rewrite goes to the LLM '
              'endpoint you configure. JotLock keeps its own copies — '
              'Daymark never modifies them.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
