import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/theme.dart';
import '../../../services/schwab/schwab_reauth_provider.dart';

class SchwabBootstrapScreen extends ConsumerStatefulWidget {
  const SchwabBootstrapScreen({super.key});

  @override
  ConsumerState<SchwabBootstrapScreen> createState() =>
      _SchwabBootstrapScreenState();
}

class _SchwabBootstrapScreenState
    extends ConsumerState<SchwabBootstrapScreen> {
  final _urlController = TextEditingController();
  bool _loading = false;
  bool _urlOpened = false;
  String? _message;
  bool _success = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _openAuthUrl() async {
    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'schwab-bootstrap',
        method: HttpMethod.get,
        queryParameters: {'action': 'auth_url'},
      );
      final data = res.data as Map<String, dynamic>?;
      final authUrl = data?['auth_url'] as String?;
      if (authUrl == null) {
        setState(() {
          _message = 'Failed to get auth URL';
          _success = false;
        });
        return;
      }
      await launchUrl(Uri.parse(authUrl), mode: LaunchMode.externalApplication);
      setState(() => _urlOpened = true);
    } catch (e) {
      setState(() {
        _message = 'Error: $e';
        _success = false;
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _submitCode() async {
    final pasted = _urlController.text.trim();
    if (pasted.isEmpty) return;

    // Accept either a full redirect URL or a bare code
    String code;
    try {
      final extracted = Uri.parse(pasted).queryParameters['code'];
      code = extracted ?? pasted;
    } catch (_) {
      code = pasted;
    }

    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'schwab-bootstrap',
        body: {'code': code},
        method: HttpMethod.post,
      );
      if (res.status == 200) {
        ref.read(schwabReauthNeededProvider.notifier).state = false;
        setState(() {
          _success = true;
          _message = 'Schwab reconnected successfully!';
        });
        await Future.delayed(const Duration(milliseconds: 1500));
        if (mounted) context.go('/');
      } else {
        final data = res.data as Map<String, dynamic>?;
        final err = data?['error'] ?? 'Token exchange failed (${res.status})';
        setState(() {
          _success = false;
          _message = err.toString();
        });
      }
    } catch (e) {
      setState(() {
        _success = false;
        _message = 'Error: $e';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Schwab')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'STEP 1',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Open the Schwab authorization page and approve read access.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loading ? null : _openAuthUrl,
              icon: _loading && !_urlOpened
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser_rounded),
              label: const Text('Open Schwab Authorization'),
            ),
            if (_urlOpened) ...[
              const SizedBox(height: 32),
              const Text(
                'STEP 2',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'After approving, copy the full URL from your browser\'s address bar and paste it below.',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _urlController,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Paste the full redirect URL here',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: AppTheme.elevatedColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                maxLines: 3,
                minLines: 1,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loading ? null : _submitCode,
                child: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Connect'),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _success
                      ? Colors.green.shade900
                      : Colors.red.shade900,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: _success
                        ? Colors.green.shade100
                        : Colors.red.shade100,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
