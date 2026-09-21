import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../api/hermes_repository.dart';
import '../../providers.dart';
import 'local_store.dart';
import 'server_url.dart';
import '../../diagnostics/diagnostics.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.initialError});
  final String? initialError;
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController url, key;
  bool obscure = true, busy = false;
  String? feedback;
  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    url = TextEditingController(text: s.url);
    key = TextEditingController(text: s.key);
    feedback = widget.initialError;
  }

  @override
  void dispose() {
    url.dispose();
    key.dispose();
    super.dispose();
  }

  AppSettings validated() {
    // One shared validator with the app-wide `configured` gate (§4.1.2):
    // nothing that passes here can produce a relative/network-less request.
    final normalized = normalizeServerUrl(url.text.trim());
    if (normalized.isEmpty) {
      throw const FormatException('請輸入有效的 http(s) Server URL（含主機，不含帳密或查詢參數）。');
    }
    if (key.text.trim().isEmpty) throw const FormatException('請輸入 API key。');
    return AppSettings(url: normalized, key: key.text.trim());
  }

  Future<void> test() async {
    setState(() {
      busy = true;
      feedback = null;
    });
    HermesRepository? repo;
    try {
      final s = validated();
      repo = HermesRepository(s.url, s.key);
      await repo.checkCapabilities();
      final alive = await repo.health();
      if (mounted) {
        setState(() => feedback = alive ? '連線成功，串流聊天可用。' : '相容性通過，但健康檢查失敗。');
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => feedback = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => feedback = '無法連線：請確認裝置可連線至伺服器（若伺服器在私人網路，先連上該網路），並檢查 URL 與 API key。',
        );
      }
    } finally {
      repo?.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      await ref.read(settingsProvider.notifier).save(validated());
      if (mounted && Navigator.canPop(context)) Navigator.pop(context);
    } on FormatException catch (e) {
      if (mounted) setState(() => feedback = e.message);
    } catch (_) {
      if (mounted) setState(() => feedback = '安全儲存失敗，設定尚未儲存。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('連線設定')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Icon(
              Icons.hub_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.primary,
            ),
            ListTile(
              title: Text('App 版本：${Diagnostics.current?.version ?? '無法讀取'}'),
              subtitle: const Text(
                '診斷檔含 SSE 事件與 heartbeat 時間，不含對話內容或金鑰。儲存後可回傳檔案。',
              ),
            ),
            OutlinedButton.icon(
              onPressed: Diagnostics.current == null
                  ? null
                  : () async {
                      try {
                        final saved = await Diagnostics.current!.export();
                        if (mounted) {
                          setState(
                            () => feedback = saved ? '診斷檔已儲存，可回傳檔案。' : '已取消儲存',
                          );
                        }
                      } catch (_) {
                        if (mounted) setState(() => feedback = '診斷檔匯出失敗，請重試。');
                      }
                    },
              icon: const Icon(Icons.save_alt),
              label: const Text('匯出診斷 log'),
            ),
            const SizedBox(height: 24),
            Text(
              '連接你的 Hermes',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              '輸入你的 Hermes server URL 與 API key。確認裝置可連線至伺服器；若使用私人網路，請先連上該網路。',
            ),
            const SizedBox(height: 32),
            TextField(
              controller: url,
              enabled: !busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: key,
              enabled: !busy,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: obscure ? '顯示金鑰' : '隱藏金鑰',
                  onPressed: () => setState(() => obscure = !obscure),
                  icon: Icon(
                    obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text('金鑰儲存在此裝置的安全儲存空間。', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 24),
            if (feedback != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(feedback!),
              ),
            OutlinedButton.icon(
              onPressed: busy ? null : test,
              icon: const Icon(Icons.network_check),
              label: const Text('測試連線'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: busy ? null : save,
              child: const Text('儲存設定'),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    ),
  );
}
