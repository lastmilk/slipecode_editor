import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/plugin.dart';
import '../../services/lua/lua_permission_service.dart';
import '../../services/lua/lua_runtime_service.dart';
import '../../services/plugin_market_service.dart';
import '../../services/plugin_service.dart';

/// 插件中心：已安装 / 插件市场
///
/// 插件与 Payload 无关——这里管理的是 IDE 体验（语言 LSP、命令、片段、主题），
/// 项目模板（Payload）在创建项目时选择。
class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key});

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  @override
  void initState() {
    super.initState();
    PluginService.instance.ensureLoaded();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: '已安装'),
            Tab(text: '插件市场'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '从本地目录安装',
            icon: const Icon(Icons.folder_open),
            onPressed: _installFromDirectory,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _InstalledTab(
            isDark: isDark,
            onBrowseMarket: () => _tab.animateTo(1),
          ),
          _MarketTab(isDark: isDark),
        ],
      ),
    );
  }

  Future<void> _installFromDirectory() async {
    String? path;
    try {
      path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择插件目录（需包含 metadata.xml 或 plugin.json）',
      );
    } catch (e) {
      _toast('无法打开目录选择器：$e');
      return;
    }
    if (path == null) return;
    try {
      final plugin = await PluginService.instance.installFromDirectory(path);
      final needsGrant =
          plugin.isLua &&
          plugin.luaManifest!.requestsEditorModify &&
          !LuaPermissionService.instance.isGranted(plugin);
      _toast('已安装 ${plugin.manifest.name}${needsGrant ? '，未获修改授权' : ''}');
    } catch (e) {
      _toast('安装失败：$e');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

// ---------------------------------------------------------------------------
// 已安装
// ---------------------------------------------------------------------------

class _InstalledTab extends StatelessWidget {
  const _InstalledTab({required this.isDark, required this.onBrowseMarket});

  final bool isDark;
  final VoidCallback onBrowseMarket;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        PluginService.instance,
        LuaRuntimeService.instance,
        LuaPermissionService.instance,
      ]),
      builder: (context, _) {
        final plugins = PluginService.instance.plugins;
        if (plugins.isEmpty) {
          return _EmptyState(
            icon: Icons.extension_outlined,
            title: '还没有安装插件',
            description:
                '插件可以扩展语言服务（LSP）、命令、代码片段与主题，'
                '与项目模板（Payload）互不影响。',
            action: FilledButton.icon(
              onPressed: onBrowseMarket,
              icon: const Icon(Icons.storefront, size: 18),
              label: const Text('去插件市场看看'),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: plugins.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final plugin = plugins[index];
            return _PluginCard(
              plugin: plugin.manifest,
              isDark: isDark,
              footer: plugin.isLua ? _luaFooter(context, plugin) : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: plugin.enabled,
                    onChanged: (value) => PluginService.instance.setEnabled(
                      plugin.manifest.id,
                      value,
                    ),
                  ),
                  IconButton(
                    tooltip: '卸载',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => _confirmUninstall(context, plugin),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _luaFooter(BuildContext context, InstalledPlugin plugin) {
    final runtime = LuaRuntimeService.instance;
    final permissions = LuaPermissionService.instance;
    final lua = plugin.luaManifest!;
    final permission = permissions.status(plugin);
    final error = runtime.errorFor(lua.id);
    final status = !plugin.enabled
        ? '已禁用'
        : lua.requestsEditorModify && permission != LuaPermissionStatus.granted
        ? '${permission == LuaPermissionStatus.denied ? '未获修改授权' : '等待修改授权'}${runtime.isVmLoaded(lua.id) ? '，安全能力运行中' : ''}'
        : runtime.isVmLoaded(lua.id)
        ? '运行中'
        : '未运行';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          'LuaJIT · $status',
          style: TextStyle(
            fontSize: 11,
            color: error == null
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 4),
          Text(
            error,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          runSpacing: 0,
          children: [
            if (plugin.enabled &&
                lua.requestsEditorModify &&
                permission != LuaPermissionStatus.granted)
              TextButton(
                onPressed: () => _authorize(context, plugin),
                child: Text(
                  permission == LuaPermissionStatus.denied ? '重新授权' : '授权修改',
                ),
              ),
            if (lua.requestsEditorModify &&
                permission == LuaPermissionStatus.granted)
              TextButton(
                onPressed: () => _revoke(context, plugin),
                child: const Text('撤销授权'),
              ),
            if (plugin.enabled)
              TextButton(
                onPressed: () => _reload(context, plugin),
                child: const Text('重载'),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _authorize(BuildContext context, InstalledPlugin plugin) async {
    final permissions = LuaPermissionService.instance;
    final granted = await permissions.requestEditorModify(
      plugin,
      askAgain: permissions.status(plugin) == LuaPermissionStatus.denied,
    );
    if (granted) {
      await LuaRuntimeService.instance.loadPlugin(plugin);
    } else {
      await LuaRuntimeService.instance.unloadPlugin(plugin.manifest.id);
    }
    if (!context.mounted) return;
    _toast(context, granted ? '已授权并加载插件' : '未获修改授权');
  }

  Future<void> _revoke(BuildContext context, InstalledPlugin plugin) async {
    await LuaRuntimeService.instance.unloadPlugin(plugin.manifest.id);
    await LuaPermissionService.instance.revoke(plugin.manifest.id);
    if (!context.mounted) return;
    _toast(context, '已撤销授权并卸载插件贡献');
  }

  Future<void> _reload(BuildContext context, InstalledPlugin plugin) async {
    final refreshed = await PluginService.instance.refreshLuaPlugin(
      plugin.manifest.id,
    );
    if (refreshed == null) {
      if (!context.mounted) return;
      _toast(context, '重载失败，请检查 metadata.xml 与插件目录');
      return;
    }
    final error = LuaRuntimeService.instance.errorFor(refreshed.manifest.id);
    if (!context.mounted) return;
    _toast(context, error == null ? '插件已重载' : '重载失败：$error');
  }

  void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmUninstall(
    BuildContext context,
    InstalledPlugin plugin,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('卸载 ${plugin.manifest.name}'),
        content: const Text('插件目录与本地配置将被删除，确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await PluginService.instance.uninstall(plugin.manifest.id);
  }
}

// ---------------------------------------------------------------------------
// 插件市场
// ---------------------------------------------------------------------------

class _MarketTab extends StatefulWidget {
  const _MarketTab({required this.isDark});

  final bool isDark;

  @override
  State<_MarketTab> createState() => _MarketTabState();
}

class _MarketTabState extends State<_MarketTab>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _search = TextEditingController();
  final Set<String> _installing = {};

  String _category = '';
  String _sort = 'popular';
  bool _loading = false;
  String? _error;
  List<PluginManifest> _plugins = const [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await PluginMarketService.instance.list(
        query: _search.text,
        category: _category,
        sort: _sort,
      );
      if (!mounted) return;
      setState(() => _plugins = page.plugins);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _install(PluginManifest plugin) async {
    setState(() => _installing.add(plugin.id));
    try {
      final manifest = await PluginMarketService.instance.install(
        plugin.marketId.isEmpty ? plugin.id : plugin.marketId,
      );
      await PluginService.instance.install(
        manifest: manifest,
        source: 'market',
      );
      _toast('已安装 ${manifest.name}');
    } catch (e) {
      _toast('安装失败：$e');
    } finally {
      if (mounted) setState(() => _installing.remove(plugin.id));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _load(),
                  decoration: InputDecoration(
                    hintText: '搜索插件名称、描述或标签',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () {
                        _search.clear();
                        _load();
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _sort,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'popular', child: Text('最热')),
                  DropdownMenuItem(value: 'new', child: Text('最新')),
                  DropdownMenuItem(value: 'name', child: Text('名称')),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _sort = value);
                  _load();
                },
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: _load,
              ),
            ],
          ),
        ),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final item in const [
                ['', '全部'],
                ['language', '语言支持'],
                ['theme', '主题外观'],
                ['tools', '开发工具'],
                ['other', '其它'],
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(item[1]),
                    selected: _category == item[0],
                    onSelected: (_) {
                      setState(() => _category = item[0]);
                      _load();
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _EmptyState(
                  icon: Icons.cloud_off,
                  title: '插件市场暂不可用',
                  description: _error!,
                  action: FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                )
              : _plugins.isEmpty
              ? const _EmptyState(
                  icon: Icons.storefront_outlined,
                  title: '暂无插件',
                  description: '市场里还没有符合条件的插件，换个关键词试试。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _plugins.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final plugin = _plugins[index];
                    final installed = PluginService.instance.isInstalled(
                      plugin.id,
                    );
                    final busy = _installing.contains(plugin.id);
                    return _PluginCard(
                      plugin: plugin,
                      isDark: widget.isDark,
                      trailing: FilledButton(
                        onPressed: installed || busy
                            ? null
                            : () => _install(plugin),
                        child: Text(
                          installed ? '已安装' : (busy ? '安装中…' : '安装'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 通用组件
// ---------------------------------------------------------------------------

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.isDark,
    this.trailing,
    this.footer,
  });

  final PluginManifest plugin;
  final bool isDark;
  final Widget? trailing;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final capabilities = plugin.declaredCapabilities.isNotEmpty
        ? plugin.declaredCapabilities
        : [
            if (plugin.contributes.lspServers.isNotEmpty) 'lsp',
            if (plugin.contributes.commands.isNotEmpty) 'commands',
            if (plugin.contributes.snippets.isNotEmpty) 'snippets',
            if (plugin.contributes.themes.isNotEmpty) 'themes',
          ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF232327) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark ? Colors.white12 : const Color(0xFFE4E6EB),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary
                  .withValues(alpha: isDark ? 0.22 : 0.1),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              plugin.categoryIcon,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        plugin.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'v${plugin.version}',
                      style: TextStyle(
                        fontSize: 11,
                        color: isDark ? Colors.white38 : Colors.black38,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (plugin.publisher.isNotEmpty) plugin.publisher,
                    plugin.categoryLabel,
                  ].join(' · '),
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black45,
                  ),
                ),
                if (plugin.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    plugin.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                ],
                if (capabilities.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final capability in capabilities)
                        _CapabilityChip(label: capability, isDark: isDark),
                    ],
                  ),
                ],
                if (footer != null) footer!,
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
  }
}

class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({required this.label, required this.isDark});

  final String label;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF1F3F5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        switch (label) {
          'lsp' => '语言服务',
          'commands' => '命令',
          'snippets' => '代码片段',
          'themes' => '主题',
          _ => label,
        },
        style: TextStyle(
          fontSize: 10,
          color: isDark ? Colors.white54 : Colors.black54,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 40,
              color: isDark ? Colors.white24 : Colors.black26,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: isDark ? Colors.white38 : Colors.black45,
                ),
              ),
            ),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
