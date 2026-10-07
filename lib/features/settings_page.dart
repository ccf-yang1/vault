import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/models.dart';
import '../core/theme.dart';
import '../core/widgets.dart';
import '../data/credential_store.dart';
import '../state/session_providers.dart';
import 'cache_tasks_page.dart';
import 'connect_page.dart';
import 'theme_page.dart';

// CI 每次 push 会把 pubspec 的 PATCH +1，这里的展示值可能落后一个小版本。
const String kAppVersion = '1.0.0';

/// HTML 05 / 06：设置页。含伪装成「记录」的隐藏模式入口。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _note = TextEditingController();

  StorageType _type = StorageType.webdav;
  bool _showPassword = false;
  bool _saving = false;
  String? _saveError;
  bool _prefilled = false;
  int? _cacheBytes;
  String? _busyAccountId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCacheSize());
  }

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    _note.dispose();
    super.dispose();
  }

  void _prefill(ConnectionConfig? config) {
    if (_prefilled || config == null) return;
    _prefilled = true;
    _type = config.type;
    _url.text = config.baseUrl;
    _user.text = config.username;
    _pass.text = config.password;
  }

  Future<void> _refreshCacheSize() async {
    final bytes = await ref.read(cacheProvider).totalBytes();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  /// 隐藏入口：输入当前 HHmm 就开启，错则什么都不发生（需求 §3.7）。
  void _onNoteChanged(String value) {
    final input = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (input.length != 4) return;
    if (!matchesUnlockCode(input)) return;
    _note.clear();
    ref.read(hiddenModeProvider.notifier).state = true;
  }

  Future<void> _save() async {
    final config = ref.read(connectionConfigProvider);
    if (config == null) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final next = ConnectionConfig(
      type: _type,
      baseUrl: _url.text.trim(),
      username: _user.text.trim(),
      password: _pass.text,
      remember: config.remember,
    );
    final result = await ref.read(sessionProvider.notifier).connect(next);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saveError = result.isSuccess ? null : result.message;
    });
    if (!result.isSuccess) return;
    if (next.baseUrl != config.baseUrl || next.username != config.username) {
      // 换服务器或换账号，旧沙盒缓存基本对不上了（需求 §3.7）。
      await ref.read(cacheProvider).clear();
      await _refreshCacheSize();
    }
    if (!mounted) return;
    showVaultToast(context, '已保存并重新连接');
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(connectionConfigProvider);
    _prefill(config);
    final settings = ref.watch(settingsProvider);
    final hiddenMode = ref.watch(hiddenModeProvider);
    final hiddenDirs = ref.watch(hiddenDirsProvider);
    final cacheTasks = ref.watch(cacheTasksProvider);

    return VaultAnnotatedRegion(
      child: Scaffold(
        backgroundColor: VaultColors.bg,
        body: SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const VaultAppBar(title: '设置'),
              const SectionTitle('连接'),
              VaultCard(
                padding: const EdgeInsets.fromLTRB(15, 14, 15, 4),
                children: [
                  _segment(),
                  VaultTextField(
                    label: '服务器地址',
                    icon: 'globe',
                    controller: _url,
                    placeholder: 'https://dav.example.com/dav',
                    keyboardType: TextInputType.url,
                  ),
                  VaultTextField(
                    label: '用户名',
                    icon: 'user',
                    controller: _user,
                    placeholder: 'reader',
                  ),
                  VaultTextField(
                    label: '密码',
                    icon: 'lock',
                    controller: _pass,
                    obscure: !_showPassword,
                    placeholder: '••••••••',
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: PrimaryButton(
                            label: _saving ? '保存中' : '保存更改',
                            loading: _saving,
                            onPressed: _saving ? null : _save,
                          ),
                        ),
                        const SizedBox(width: 10),
                        IconBtn(
                          icon: _showPassword ? 'eyeOff' : 'eye',
                          color: _showPassword ? VaultColors.accent : VaultColors.muted,
                          onTap: () => setState(() => _showPassword = !_showPassword),
                        ),
                      ],
                    ),
                  ),
                  if (_saveError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _saveError!,
                        style: TextStyle(fontSize: 11.5, color: VaultColors.danger, height: 1.5),
                      ),
                    ),
                ],
              ),
              const SectionTitle('账号'),
              _accountsCard(),
              const SectionTitle('个性化'),
              VaultCard(
                padding: const EdgeInsets.fromLTRB(15, 2, 15, 2),
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ThemePage()),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          VIcon('palette', size: 16, color: VaultColors.accent),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text('外观主题', style: TextStyle(fontSize: 13, color: VaultColors.text)),
                          ),
                          Text(
                            settings.themeMode.label,
                            style: const TextStyle(fontSize: 12).copyWith(color: VaultColors.muted),
                          ),
                          const SizedBox(width: 4),
                          VIcon('chevron', size: 15, color: VaultColors.chevron),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SectionTitle('离线下载'),
              VaultCard(
                padding: const EdgeInsets.fromLTRB(15, 2, 15, 2),
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CacheTasksPage()),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          VIcon('download', size: 16, color: VaultColors.accent),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text('任务列表', style: TextStyle(fontSize: 13, color: VaultColors.text)),
                          ),
                          Text(
                            cacheTasks.isEmpty ? '浏览页长按目录提交' : '$cacheTasks 个任务',
                            style: TextStyle(fontSize: 12, color: VaultColors.muted),
                          ),
                          const SizedBox(width: 4),
                          VIcon('chevron', size: 15, color: VaultColors.chevron),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SectionTitle('记录'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: VaultColors.field,
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: VaultColors.line),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      VIcon('list', size: 15, color: VaultColors.dim),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _note,
                          onChanged: _onNoteChanged,
                          style: TextStyle(fontSize: 13.5, color: VaultColors.text),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            hintText: '输入文字…',
                            hintStyle: TextStyle(fontSize: 13.5, color: VaultColors.dim),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(18, 8, 18, 0),
                child: Text(
                  '随手记点什么，比如今天的天气。',
                  style: TextStyle(fontSize: 11, color: VaultColors.dim),
                ),
              ),
              if (hiddenMode) ...[
                const SizedBox(height: 14),
                _hiddenCard(hiddenDirs),
              ],
              const SectionTitle('存储'),
              VaultCard(
                padding: const EdgeInsets.fromLTRB(15, 2, 15, 12),
                children: [
                  _sfield('缓存', _cacheBytes == null ? '统计中…' : formatBytes(_cacheBytes!)),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      await ref.read(cacheProvider).clear();
                      await _refreshCacheSize();
                      if (!context.mounted) return;
                      showVaultToast(context, '缓存已清除');
                    },
                    child: _sfieldAction('清除缓存'),
                  ),
                  _limitRow(settings),
                  const SizedBox(height: 12),
                  ToggleRow(
                    title: '预加载',
                    subtitle: '图片前后各 5 张、目录大小统计',
                    value: settings.preloadEnabled,
                    onChanged: (value) => ref.read(settingsProvider.notifier).setPreload(value),
                  ),
                  const SizedBox(height: 10),
                  ToggleRow(
                    title: '仅 Wi-Fi 上传',
                    subtitle: '蜂窝网络下不发起上传',
                    value: settings.wifiOnlyUpload,
                    onChanged: (value) => ref.read(settingsProvider.notifier).setWifiOnly(value),
                  ),
                ],
              ),
              const SectionTitle('关于'),
              VaultCard(
                padding: const EdgeInsets.fromLTRB(15, 2, 15, 2),
                children: [
                  _sfield('版本', kAppVersion),
                  _sfield('类型', config?.type.label ?? '—'),
                  _sfield('服务器', config?.displayHost ?? '—', mono: true),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => ref.read(sessionProvider.notifier).logout(),
                    child: _sfieldAction('退出登录', danger: true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 已保存的账号列表：当前那个打勾、点别的即切换，每行可移除，末尾「添加账号」。
  Widget _accountsCard() {
    return ref.watch(accountsProvider).maybeWhen(
      data: (list) {
        final active = ref.watch(connectionConfigProvider);
        final activeId = active == null ? null : CredentialStore.idOf(active);
        return VaultCard(
          padding: const EdgeInsets.fromLTRB(15, 2, 15, 2),
          children: [
            for (final a in list) _accountRow(a, activeId == CredentialStore.idOf(a)),
            _addAccountRow(),
          ],
        );
      },
      orElse: () => const SizedBox(height: 18),
    );
  }

  Widget _accountRow(ConnectionConfig a, bool isActive) {
    final busy = _busyAccountId == CredentialStore.idOf(a);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: (isActive || busy) ? null : () => _switchAccount(a),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            VIcon(isActive ? 'check' : 'user', size: 16, color: isActive ? VaultColors.accent : VaultColors.dim),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.username.isEmpty ? a.displayHost : a.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive ? VaultColors.text : VaultColors.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    a.displayHost,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: VaultColors.dim),
                  ),
                ],
              ),
            ),
            if (busy)
              SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2, color: VaultColors.accent),
              )
            else
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _removeAccount(a),
                child: Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: VIcon('close', size: 15, color: VaultColors.dim),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _addAccountRow() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ConnectPage(addMode: true)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            VIcon('plus', size: 16, color: VaultColors.accent),
            SizedBox(width: 11),
            Text('添加账号', style: TextStyle(fontSize: 13, color: VaultColors.accent)),
          ],
        ),
      ),
    );
  }

  Future<void> _switchAccount(ConnectionConfig a) async {
    final old = ref.read(connectionConfigProvider);
    setState(() => _busyAccountId = CredentialStore.idOf(a));
    final result = await ref.read(accountsProvider.notifier).use(a);
    if (!mounted) return;
    setState(() => _busyAccountId = null);
    if (!result.isSuccess) {
      showVaultToast(context, result.message, error: true);
      return;
    }
    // 换到另一台服务器，旧沙盒缓存基本对不上了，清掉更干净（需求 §3.7）。
    if (old != null && old.baseUrl != a.baseUrl) {
      await ref.read(cacheProvider).clear();
      await _refreshCacheSize();
    }
  }

  Future<void> _removeAccount(ConnectionConfig a) async {
    final label = a.username.isEmpty ? a.displayHost : '${a.username}@${a.displayHost}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: VaultColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('移除账号', style: TextStyle(fontSize: 16, color: VaultColors.text)),
        content: Text(
          '把 $label 从本机移除？只影响这台设备上的登录信息，不会删服务器上的文件。',
          style: TextStyle(fontSize: 13, color: VaultColors.muted, height: 1.6),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('移除', style: TextStyle(color: VaultColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(accountsProvider.notifier).remove(a);
    if (!mounted) return;
    showVaultToast(context, '已移除 $label');
  }

  Widget _segment() {
    Widget item(StorageType type, String label) {
      final active = _type == type;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _type = type),
          child: Container(
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? VaultColors.segActive : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: active ? VaultColors.text : VaultColors.muted),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: VaultColors.fieldFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VaultColors.line),
      ),
      child: Row(
        children: [
          item(StorageType.webdav, 'WebDAV'),
          item(StorageType.openlist, 'OpenList'),
        ],
      ),
    );
  }

  Widget _hiddenCard(List<HiddenEntry> dirs) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VaultColors.purple.withValues(alpha: 0.22)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            VaultColors.purple.withValues(alpha: 0.09),
            VaultColors.purple.withValues(alpha: 0.025),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 13, 15, 8),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: VaultColors.purple,
                    boxShadow: [BoxShadow(color: VaultColors.purple.withValues(alpha: 0.9), blurRadius: 8)],
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('隐藏模式已开启', style: TextStyle(fontSize: 13, color: Color(0xFFCFC2E8))),
                ),
                Text('${dirs.length} 个目录', style: TextStyle(fontSize: 11, color: VaultColors.purpleDeep)),
              ],
            ),
          ),
          if (dirs.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(15, 0, 15, 12),
              child: Text(
                '还没有隐藏任何目录。在浏览页点行右侧的眼睛即可隐藏。',
                style: TextStyle(fontSize: 11.5, color: VaultColors.purpleDeep, height: 1.6),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 4),
              child: Column(
                children: [
                  for (final dir in dirs)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: const BoxDecoration(
                        border: Border(bottom: BorderSide(color: Color(0x1FA98CD8))),
                      ),
                      child: Row(
                        children: [
                          VIcon('folder', size: 14, color: VaultColors.purpleDeep),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              dir.path,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFB8A9D6),
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => ref.read(hiddenDirsProvider.notifier).setHidden(
                                  RemoteEntry(name: dir.name, path: dir.path, isDir: true),
                                  false,
                                ),
                            child: Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: VIcon('close', size: 14, color: VaultColors.purpleDeep),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => ref.read(hiddenModeProvider.notifier).state = false,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 11),
              child: Text(
                '退出隐藏模式',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: VaultColors.purpleDeep),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sfield(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 62,
            child: Text(label, style: TextStyle(fontSize: 12.5, color: VaultColors.dim)),
          ),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: mono ? 12 : 12.5,
                color: VaultColors.text,
                fontFeatures: mono ? const [FontFeature.tabularFigures()] : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sfieldAction(String label, {bool danger = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const SizedBox(width: 62),
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12.5,
                color: danger ? VaultColors.danger : VaultColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _limitRow(AppSettings settings) {
    const options = [200, 500, 1000, 2000];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 62,
                child: Text('上限', style: TextStyle(fontSize: 12.5, color: VaultColors.dim)),
              ),
              Expanded(
                child: Text(
                  '${settings.cacheLimitMB} MB · 超出删最旧',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: VaultColors.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final mb in options)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => ref.read(settingsProvider.notifier).setCacheLimit(mb),
                    child: Container(
                      height: 34,
                      margin: EdgeInsets.only(right: mb == 2000 ? 0 : 7),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: settings.cacheLimitMB == mb ? VaultColors.segActive : VaultColors.field,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: settings.cacheLimitMB == mb
                              ? VaultColors.accent.withValues(alpha: 0.5)
                              : VaultColors.line,
                        ),
                      ),
                      child: Text(
                        '$mb',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: settings.cacheLimitMB == mb ? VaultColors.accentText : VaultColors.muted,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
