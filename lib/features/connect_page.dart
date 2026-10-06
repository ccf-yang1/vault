import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../state/session_providers.dart';

/// HTML 01：连接页。分段控件 + 三个输入框 + 记住凭据 + 安全提示。
class ConnectPage extends ConsumerStatefulWidget {
  const ConnectPage({super.key});

  @override
  ConsumerState<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends ConsumerState<ConnectPage> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  StorageType _type = StorageType.webdav;
  bool _remember = true;
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  ConnectAttempt? _attempt;
  bool _showLog = false;

  @override
  void initState() {
    super.initState();
    _prefillSaved();
  }

  Future<void> _prefillSaved() async {
    final saved = await ref.read(credentialStoreProvider).load();
    if (saved == null || !mounted) return;
    // 自动登录失败才会走到这里，把上次的信息填回去，用户只改错的那一项。
    setState(() {
      _type = saved.type;
      _remember = saved.remember;
      if (_url.text.isEmpty) _url.text = saved.baseUrl;
      if (_user.text.isEmpty) _user.text = saved.username;
      if (_pass.text.isEmpty) _pass.text = saved.password;
    });
    // 自动登录失败是不弹错的（免得开屏就跳告警），但过程得留在这里，
    // 否则用户只会看到一张空表单，完全不知道刚才发生了什么。
    final attempt = ref.read(sessionProvider.notifier).lastAttempt;
    if (attempt != null && !attempt.ok && mounted) {
      setState(() {
        _attempt = attempt;
        _error = attempt.advice;
        _showLog = true;
      });
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _connect({bool allowInsecure = false}) async {
    setState(() {
      _busy = true;
      _error = null;
      _attempt = null;
    });
    final config = ConnectionConfig(
      type: _type,
      baseUrl: _url.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      remember: _remember,
    );
    if (config.baseUrl.isEmpty) {
      setState(() {
        _busy = false;
        _error = '请先填写服务器地址';
      });
      return;
    }
    final result = await ref.read(sessionProvider.notifier).connect(config, allowInsecure: allowInsecure);
    if (!mounted) return;
    if (result.isSuccess) {
      setState(() => _busy = false);
      return; // redirect 会把我们换成主框架
    }
    if (result.needsCertificateWarning && !allowInsecure) {
      setState(() => _busy = false);
      final proceed = await _askInsecure();
      if (proceed == true && mounted) await _connect(allowInsecure: true);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.message;
      _attempt = result.attempt;
      _showLog = true;
    });
  }

  Future<bool?> _askInsecure() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VaultColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('证书不受信任', style: TextStyle(fontSize: 16, color: VaultColors.text)),
        content: const Text(
          '服务器使用的是自签名或已过期证书。继续连接会绕过证书校验，仅在你信任这台机器时选择继续。',
          style: TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('继续连接')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return VaultAnnotatedRegion(
      child: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 28),
            children: [
              const SizedBox(height: 18),
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF232A3A), Color(0xFF141821)],
                  ),
                  borderRadius: BorderRadius.circular(17),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.075)),
                  boxShadow: [
                    BoxShadow(
                      color: VaultColors.accent.withValues(alpha: 0.5),
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: const Center(child: VIcon('brand', size: 26, color: Color(0xFF7D93E8))),
              ),
              const SizedBox(height: 22),
              const Text('连接到你的存储', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Color(0xFFF0F1F3))),
              const SizedBox(height: 9),
              const Text(
                '支持 WebDAV 与 OpenList。\n凭据将保存在 App 沙盒内，仅用于本机自动登录。',
                style: TextStyle(fontSize: 12.5, color: VaultColors.muted, height: 1.65),
              ),
              const SizedBox(height: 22),
              _segment(),
              const SizedBox(height: 20),
              VaultTextField(
                label: '服务器地址',
                icon: 'globe',
                controller: _url,
                placeholder: _type == StorageType.openlist
                    ? 'http://192.168.1.100:5244/dav'
                    : 'https://dav.example.com/dav',
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _focusNext(_user),
              ),
              VaultTextField(
                label: '用户名',
                icon: 'user',
                controller: _user,
                placeholder: 'admin',
                keyboardType: TextInputType.name,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _focusNext(_pass),
              ),
              VaultTextField(
                label: '密码',
                icon: 'lock',
                controller: _pass,
                obscure: _obscure,
                placeholder: '••••••••',
              ),
              _passwordToggle(),
              const SizedBox(height: 8),
              ToggleRow(
                title: '在此设备记住凭据',
                subtitle: '加密存于 App 沙盒，下次打开自动登录',
                value: _remember,
                onChanged: (v) => setState(() => _remember = v),
              ),
              const SizedBox(height: 18),
              PrimaryButton(label: _busy ? '连接中' : '连 接', loading: _busy, onPressed: _connect),
              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A1E21),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x33E0736A)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const VIcon('shield', size: 14, color: Color(0xFFE0736A)),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(fontSize: 12.5, color: Color(0xFFF0C6C2), height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              _diagnostics(),
              const SizedBox(height: 15),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  VIcon('shield', size: 13, color: VaultColors.dim),
                  SizedBox(width: 6),
                  Text('缓存不写入系统相册 · 相册 App 无法索引', style: TextStyle(fontSize: 11.5, color: VaultColors.dim)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _focusNext(TextEditingController next) => next.selection = TextSelection.collapsed(offset: next.text.length);

  /// `.seg`：WebDAV / OpenList 分段控件。两者 v1 都走 WebDAV 协议，只是提示语不同。
  Widget _segment() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF15171A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VaultColors.line),
      ),
      child: Row(
        children: [
          for (final type in StorageType.values)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _type = type),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: type == _type ? const Color(0xFF252932) : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: type == _type
                        ? const [BoxShadow(color: Color(0x66000000), blurRadius: 3, offset: Offset(0, 1))]
                        : null,
                  ),
                  child: Text(
                    type.label,
                    style: TextStyle(
                      fontSize: 13,
                      color: type == _type ? VaultColors.text : VaultColors.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 失败时把这次请求的完整过程摊开：光一句「无法连接服务器」没法定位，
  /// 得让人看见真正发出去的 URL、HTTP 状态码和系统回的原话。
  Widget _diagnostics() {
    final attempt = _attempt;
    if (attempt == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _showLog = !_showLog),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                VIcon('list', size: 13, color: VaultColors.dim),
                SizedBox(width: 7),
                Text('登录日志', style: TextStyle(fontSize: 12, color: VaultColors.muted)),
                Spacer(),
                Text('展开 / 收起', style: TextStyle(fontSize: 11, color: VaultColors.dim)),
              ],
            ),
          ),
        ),
        if (_showLog)
          Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: const Color(0xFF131518),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: VaultColors.line),
            ),
            child: SelectableText(
              attempt.render(),
              style: const TextStyle(
                fontSize: 11,
                height: 1.65,
                fontFamily: 'Menlo',
                color: VaultColors.muted,
              ),
            ),
          ),
      ],
    );
  }

  Widget _passwordToggle() {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () => setState(() => _obscure = !_obscure),
        style: TextButton.styleFrom(foregroundColor: const Color(0xFF4A5058)),
        icon: VIcon(_obscure ? 'eye' : 'eyeOff', size: 15, color: const Color(0xFF4A5058)),
        label: Text(_obscure ? '显示密码' : '隐藏密码', style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}

/// 自动登录期间显示的空白页，避免闪一下连接页。
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const VaultAnnotatedRegion(
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.2, color: VaultColors.accent),
          ),
        ),
      ),
    );
  }
}
