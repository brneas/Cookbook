import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../app/providers.dart';
import '../../../core/errors/app_failure.dart';
import '../../../core/auth/auth_diagnostics.dart';
import 'login_controller.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});
  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _server = TextEditingController(),
      _login = TextEditingController(),
      _password = TextEditingController();
  bool _manual = false, _appPasswordConfirmed = false;
  @override
  void initState() {
    super.initState();
    final account = ref.read(accountProvider).asData?.value;
    if (account != null) {
      _server.text = account.server.toString();
      _login.text = account.loginName;
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _login.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final ok = await ref
        .read(loginProvider.notifier)
        .connect(
          _server.text,
          loginName: _manual ? _login.text : null,
          appPassword: _manual ? _password.text : null,
          appPasswordConfirmed: _appPasswordConfirmed,
        );
    if (!mounted) return;
    _password.clear();
    if (ok) context.go('/library');
  }

  @override
  Widget build(BuildContext context) {
    final login = ref.watch(loginProvider),
        account = ref.watch(accountProvider);
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !login.busy,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) ref.read(loginProvider.notifier).cancel();
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(28),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.menu_book_outlined,
                        size: 38,
                        color: colors.onPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Cookbook',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text('Unofficial client for Nextcloud Cookbook'),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _server,
                    enabled: !login.busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Nextcloud server',
                      hintText: 'https://cloud.example.com',
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_manual) ...[
                    TextField(
                      controller: _login,
                      enabled: !login.busy,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Login name',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _password,
                      enabled: !login.busy,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Nextcloud app password',
                        helperText:
                            'Create one in Nextcloud → Personal settings → Security.',
                        helperMaxLines: 3,
                      ),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _appPasswordConfirmed,
                      onChanged: login.busy
                          ? null
                          : (v) => setState(
                              () => _appPasswordConfirmed = v ?? false,
                            ),
                      title: const Text(
                        'This is a dedicated app password, not my normal account password.',
                      ),
                    ),
                  ] else
                    const Text(
                      "You'll sign in securely in your browser. Cookbook never receives your normal Nextcloud password.",
                    ),
                  const SizedBox(height: 20),
                  if (login.error != null || account.hasError)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        login.errorMessage ??
                            safeFailure(account.error!).message,
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                  if (login.recoverable)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Your one-time application credentials are retained securely. Retry with this server to resume verification without repeating authorization.',
                      ),
                    ),
                  if (login.diagnostic != null)
                    ExpansionTile(
                      title: const Text('Technical details'),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(login.diagnostic!.text),
                        ),
                      ],
                    ),
                  if (login.busy) ...[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 16),
                    Semantics(liveRegion: true, child: Text(login.stage.label)),
                    TextButton(
                      onPressed: () =>
                          ref.read(loginProvider.notifier).cancel(),
                      child: const Text('Cancel sign-in'),
                    ),
                  ] else ...[
                    if (login.error?.kind == FailureKind.browser)
                      OutlinedButton.icon(
                        onPressed: () =>
                            ref.read(loginProvider.notifier).reopenBrowser(),
                        icon: const Icon(Icons.open_in_browser),
                        label: const Text('Open browser'),
                      ),
                    FilledButton.icon(
                      onPressed: account.isLoading ? null : _connect,
                      icon: Icon(
                        _manual ? Icons.key_outlined : Icons.open_in_browser,
                      ),
                      label: Text(
                        _manual
                            ? 'Connect with app password'
                            : 'Connect to Nextcloud',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => setState(() {
                        _manual = !_manual;
                        _password.clear();
                        _appPasswordConfirmed = false;
                      }),
                      child: Text(
                        _manual
                            ? 'Use browser sign-in'
                            : 'Advanced: use an app password',
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Text('No ads · No analytics · Your server'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
