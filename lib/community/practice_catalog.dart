import '../services/tutorial_service.dart';

/// 单节课程对应的实操练习
///
/// 检查口径：不要求与参考答案逐字一致，只要覆盖需求中的关键结构
/// （requiredTokens）且没有遗留 TODO / 明显语法问题即可通过。
class PracticeSpec {
  final String lessonId;
  final String title;
  final String requirement;
  final String starter;
  final String answer;
  final List<String> hints;
  final List<String> requiredTokens;
  final List<String> forbiddenTokens;

  /// 最佳实践类题目使用更严格的检查（禁止 print、要求 const 等）
  final bool strict;

  const PracticeSpec({
    required this.lessonId,
    required this.title,
    required this.requirement,
    required this.starter,
    required this.answer,
    this.hints = const [],
    this.requiredTokens = const [],
    this.forbiddenTokens = const [],
    this.strict = false,
  });

  /// 根据课程生成实操；课程表未收录时从代码示例自动兜底
  factory PracticeSpec.forLesson(TutorialLesson lesson) {
    final spec = _catalog[lesson.id];
    if (spec != null) return spec;
    final code = lesson.steps
            .where((s) => s.type == 'code' && s.code.trim().isNotEmpty)
            .map((s) => s.code)
            .firstOrNull ??
        '';
    final tokens = RegExp(r'\b(class|Widget|StatelessWidget|StatefulWidget)\b')
            .allMatches(code)
            .isEmpty
        ? <String>['Widget']
        : <String>[
            if (code.contains('StatelessWidget')) 'StatelessWidget',
            if (code.contains('StatefulWidget')) 'StatefulWidget',
            if (code.contains('MaterialApp')) 'MaterialApp',
            if (code.contains('Scaffold')) 'Scaffold',
          ];
    return PracticeSpec(
      lessonId: lesson.id,
      title: lesson.title,
      requirement: '${lesson.summary}\n\n请补全 lib/main.dart，实现课程示例中的核心界面。',
      starter: _defaultStarter,
      answer: code.isEmpty
          ? _defaultStarter.replaceAll('// TODO:', '//')
          : code,
      hints: [lesson.summary],
      requiredTokens: tokens.isEmpty ? const ['Widget'] : tokens,
    );
  }
}

const String _defaultStarter = r'''import 'package:flutter/material.dart';

void main() {
  // TODO: 调用 runApp 挂载根组件
}

class PracticeApp extends StatelessWidget {
  const PracticeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // TODO: 按需求实现页面
    return const MaterialApp(home: Scaffold(body: SizedBox()));
  }
}
''';

const Map<String, PracticeSpec> _catalog = {
  'flutter-01': PracticeSpec(
    lessonId: 'flutter-01',
    title: '第一个 Flutter 应用',
    requirement:
        '补全 lib/main.dart：实现 main() 调用 runApp，创建 MyApp（StatelessWidget），'
        '首页居中显示文字「Hello SLIPE」。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(body: Center(child: Text('Hello SLIPE'))),
    );
  }
}
''',
    hints: ['入口必须是 void main()', 'runApp 接收根 Widget', '用 Center 居中 Text'],
    requiredTokens: ['void main', 'runApp', 'MaterialApp', 'Center', 'Hello SLIPE'],
  ),
  'flutter-02': PracticeSpec(
    lessonId: 'flutter-02',
    title: 'Flutter 项目结构',
    requirement:
        '补全 lib/main.dart，把首页拆成独立的 HomePage Widget（StatelessWidget），'
        '并在 MyApp 中通过 home: HomePage() 引用，理解 Widget 与项目文件的职责划分。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: HomePage());
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('HomePage')),
    );
  }
}
''',
    hints: ['每个 Widget 单独成类', 'MaterialApp 的 home 指向 HomePage'],
    requiredTokens: ['class HomePage', 'StatelessWidget', 'home: HomePage'],
  ),
  'flutter-03': PracticeSpec(
    lessonId: 'flutter-03',
    title: 'Widget 基础',
    requirement:
        '实现一个 StatefulWidget 计数器：页面显示当前次数，点击按钮后 setState 让数字 +1。',
    starter: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: CounterPage());
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  // TODO: 定义计数状态

  @override
  Widget build(BuildContext context) {
    // TODO: 显示计数并提供 +1 按钮
    return const Scaffold(body: SizedBox());
  }
}
''',
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: CounterPage());
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$count'),
            ElevatedButton(
              onPressed: () => setState(() => count++),
              child: const Text('+1'),
            ),
          ],
        ),
      ),
    );
  }
}
''',
    hints: ['State 类里保存 int 字段', '通过 setState 更新字段', 'Text 用字符串插值显示'],
    requiredTokens: ['StatefulWidget', 'setState', 'int count', 'ElevatedButton'],
  ),
  'flutter-04': PracticeSpec(
    lessonId: 'flutter-04',
    title: 'StatelessWidget',
    requirement:
        '实现一个 Greeting 组件：接收 name 参数，居中显示「Hello, {name}」，'
        '在首页传入你的名字。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: Scaffold(body: Greeting(name: 'SLIPE')));
  }
}

class Greeting extends StatelessWidget {
  const Greeting({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return Center(child: Text('Hello, $name'));
  }
}
''',
    hints: ['构造函数加 required this.name', 'build 中直接用 name'],
    requiredTokens: ['class Greeting', 'final String name', 'required this.name', 'Hello, \$name'],
  ),
  'flutter-05': PracticeSpec(
    lessonId: 'flutter-05',
    title: '布局基础',
    requirement:
        '使用 Row + Expanded 实现左右两栏：左栏固定 100 宽并显示「左」，右栏自适应并显示「右」。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            SizedBox(width: 100, child: Center(child: Text('左'))),
            Expanded(child: Center(child: Text('右'))),
          ],
        ),
      ),
    );
  }
}
''',
    hints: ['Row 子项按顺序横向排列', 'Expanded 占满剩余空间', '固定宽度用 SizedBox'],
    requiredTokens: ['Row', 'Expanded', 'SizedBox(width: 100', 'Text(\'左\')', 'Text(\'右\')'],
  ),
  'flutter-06': PracticeSpec(
    lessonId: 'flutter-06',
    title: 'Container',
    requirement:
        '用 Container 画一张卡片：宽高 200x120，圆角 16，浅蓝背景，内边距 16，'
        '中间显示「SLIPE」。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Container(
            width: 200,
            height: 120,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Center(child: Text('SLIPE')),
          ),
        ),
      ),
    );
  }
}
''',
    hints: ['尺寸用 width / height', '圆角在 BoxDecoration.borderRadius', '内边距用 padding'],
    requiredTokens: ['Container', 'BoxDecoration', 'BorderRadius.circular(16)', 'EdgeInsets.all(16)'],
  ),
  'flutter-07': PracticeSpec(
    lessonId: 'flutter-07',
    title: 'ListView',
    requirement:
        '用 ListView.builder 渲染 20 条数据，每条显示「Item 0」…「Item 19」，'
        '点击任意条目弹出 SnackBar 显示序号。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: ListPage());
}

class ListPage extends StatelessWidget {
  const ListPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView.builder(
        itemCount: 20,
        itemBuilder: (context, index) {
          return ListTile(
            title: Text('Item $index'),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('第 $index 条')),
              );
            },
          );
        },
      ),
    );
  }
}
''',
    hints: ['itemCount 控制数量', 'itemBuilder 返回每一行', 'SnackBar 需要 ScaffoldMessenger'],
    requiredTokens: ['ListView.builder', 'itemCount: 20', 'itemBuilder', 'ScaffoldMessenger'],
  ),
  'flutter-08': PracticeSpec(
    lessonId: 'flutter-08',
    title: '用户输入',
    requirement:
        '实现输入框 + 提交按钮：用户输入文字后点击按钮，在下方显示输入内容；'
        '使用 TextEditingController 读取文本。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: InputPage());
}

class InputPage extends StatefulWidget {
  const InputPage({super.key});

  @override
  State<InputPage> createState() => _InputPageState();
}

class _InputPageState extends State<InputPage> {
  final controller = TextEditingController();
  String text = '';

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: controller),
            ElevatedButton(
              onPressed: () => setState(() => text = controller.text),
              child: const Text('提交'),
            ),
            Text(text),
          ],
        ),
      ),
    );
  }
}
''',
    hints: ['TextEditingController 记得 dispose', 'controller.text 读取内容', 'setState 刷新界面'],
    requiredTokens: ['TextEditingController', 'TextField', 'controller.text', 'setState'],
  ),
  'flutter-09': PracticeSpec(
    lessonId: 'flutter-09',
    title: '状态管理',
    requirement:
        '实现一个待办计数：页面显示已完成数量/总数，点击按钮切换完成状态，'
        '使用 setState 管理局部状态。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: TodoPage());
}

class TodoPage extends StatefulWidget {
  const TodoPage({super.key});

  @override
  State<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends State<TodoPage> {
  final List<bool> done = [false, false, false];

  @override
  Widget build(BuildContext context) {
    final completed = done.where((e) => e).length;
    return Scaffold(
      body: Column(
        children: [
          Text('已完成 $completed/${done.length}'),
          for (var i = 0; i < done.length; i++)
            CheckboxListTile(
              value: done[i],
              title: Text('任务 ${i + 1}'),
              onChanged: (v) => setState(() => done[i] = v ?? false),
            ),
        ],
      ),
    );
  }
}
''',
    hints: ['用 List<bool> 保存状态', 'where((e) => e).length 统计已完成', 'setState 内更新列表元素'],
    requiredTokens: ['StatefulWidget', 'setState', 'CheckboxListTile', 'done'],
  ),
  'flutter-10': PracticeSpec(
    lessonId: 'flutter-10',
    title: 'HTTP 请求',
    requirement:
        '使用 http 包发起 GET 请求（地址任意），设置 10 秒超时，'
        '把响应状态码显示在页面；捕获异常并展示错误信息。',
    starter: r'''import 'package:flutter/material.dart';
// TODO: 引入 http 包

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: HttpPage());
}

class HttpPage extends StatefulWidget {
  const HttpPage({super.key});

  @override
  State<HttpPage> createState() => _HttpPageState();
}

class _HttpPageState extends State<HttpPage> {
  String result = '未请求';

  Future<void> load() async {
    // TODO: 发起 GET 并处理超时与异常
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(result),
            ElevatedButton(onPressed: load, child: const Text('请求')),
          ],
        ),
      ),
    );
  }
}
''',
    answer: r'''import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: HttpPage());
}

class HttpPage extends StatefulWidget {
  const HttpPage({super.key});

  @override
  State<HttpPage> createState() => _HttpPageState();
}

class _HttpPageState extends State<HttpPage> {
  String result = '未请求';

  Future<void> load() async {
    try {
      final res = await http
          .get(Uri.parse('https://example.com'))
          .timeout(const Duration(seconds: 10));
      setState(() => result = 'HTTP ${res.statusCode}');
    } catch (e) {
      setState(() => result = '请求失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(result),
            ElevatedButton(onPressed: load, child: const Text('请求')),
          ],
        ),
      ),
    );
  }
}
''',
    hints: ['await http.get(...)', '.timeout(Duration(seconds: 10))', 'try/catch 包住请求'],
    requiredTokens: ['package:http/http.dart', 'http.get', 'timeout', 'try', 'catch'],
  ),
  'flutter-11': PracticeSpec(
    lessonId: 'flutter-11',
    title: '导航与路由',
    requirement:
        '实现两个页面：首页点击按钮 Navigator.push 进入详情页，详情页可以 Navigator.pop 返回。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: FirstPage());
}

class FirstPage extends StatelessWidget {
  const FirstPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DetailPage()),
          ),
          child: const Text('进入详情'),
        ),
      ),
    );
  }
}

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('详情')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('返回'),
        ),
      ),
    );
  }
}
''',
    hints: ['Navigator.push + MaterialPageRoute', 'Navigator.pop 返回上一页'],
    requiredTokens: ['Navigator.push', 'MaterialPageRoute', 'Navigator.pop'],
  ),
  'flutter-12': PracticeSpec(
    lessonId: 'flutter-12',
    title: '表单与验证',
    requirement:
        '用 Form + TextFormField 做邮箱输入：为空或格式不正确时提示错误，'
        '校验通过后弹 SnackBar。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: FormPage());
}

class FormPage extends StatefulWidget {
  const FormPage({super.key});

  @override
  State<FormPage> createState() => _FormPageState();
}

class _FormPageState extends State<FormPage> {
  final formKey = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Form(
        key: formKey,
        child: Column(
          children: [
            TextFormField(
              validator: (v) {
                final value = v?.trim() ?? '';
                if (value.isEmpty) return '请输入邮箱';
                if (!value.contains('@')) return '邮箱格式不正确';
                return null;
              },
            ),
            ElevatedButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('提交成功')),
                  );
                }
              },
              child: const Text('提交'),
            ),
          ],
        ),
      ),
    );
  }
}
''',
    hints: ['GlobalKey<FormState> 控制表单', 'validator 返回 String 表示错误', 'validate() 触发校验'],
    requiredTokens: ['Form(', 'TextFormField', 'validator', 'GlobalKey<FormState>', 'validate()'],
  ),
  'flutter-13': PracticeSpec(
    lessonId: 'flutter-13',
    title: '主题与样式',
    requirement:
        '给 MaterialApp 配置 ThemeData：使用 seedColor 生成配色，'
        '并把 Scaffold 背景设为浅灰。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
      ),
      home: const Scaffold(body: Center(child: Text('Theme'))),
    );
  }
}
''',
    hints: ['ThemeData 传给 MaterialApp.theme', 'ColorScheme.fromSeed 生成配色'],
    requiredTokens: ['ThemeData', 'ColorScheme.fromSeed', 'scaffoldBackgroundColor'],
  ),
  'flutter-14': PracticeSpec(
    lessonId: 'flutter-14',
    title: '动画基础',
    requirement:
        '用 AnimationController + Tween 实现一个方块在 1 秒内从透明变为不透明，'
        '进入页面自动播放。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: FadePage());
}

class FadePage extends StatefulWidget {
  const FadePage({super.key});

  @override
  State<FadePage> createState() => _FadePageState();
}

class _FadePageState extends State<FadePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..forward();

  late final Animation<double> opacity =
      Tween<double>(begin: 0, end: 1).animate(controller);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FadeTransition(
          opacity: opacity,
          child: Container(width: 120, height: 120, color: Colors.teal),
        ),
      ),
    );
  }
}
''',
    hints: ['需要 SingleTickerProviderStateMixin', 'Tween.animate(controller)', 'FadeTransition 接收 opacity'],
    requiredTokens: [
      'AnimationController',
      'Tween<double>',
      'SingleTickerProviderStateMixin',
      'FadeTransition'
    ],
  ),
  'flutter-15': PracticeSpec(
    lessonId: 'flutter-15',
    title: '本地存储',
    requirement:
        '用 shared_preferences 保存并读取一个字符串（键名任意），启动时读取并显示。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: StorePage());
}

class StorePage extends StatefulWidget {
  const StorePage({super.key});

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  String value = '';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      setState(() => value = prefs.getString('demo') ?? '空');
    });
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('demo', 'SLIPE');
    setState(() => value = 'SLIPE');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value),
            ElevatedButton(onPressed: save, child: const Text('保存')),
          ],
        ),
      ),
    );
  }
}
''',
    hints: ['SharedPreferences.getInstance()', 'getString / setString', '异步后 setState'],
    requiredTokens: ['shared_preferences', 'getInstance()', 'getString', 'setString'],
  ),
  'flutter-16': PracticeSpec(
    lessonId: 'flutter-16',
    title: '图片与资源',
    requirement:
        '使用 Image.network 显示一张网络图片，设置宽高 200x200 与 fit 裁剪，'
        '加载失败时显示占位图标。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Image.network(
            'https://picsum.photos/200',
            width: 200,
            height: 200,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stack) =>
                const Icon(Icons.image_not_supported, size: 48),
          ),
        ),
      ),
    );
  }
}
''',
    hints: ['Image.network 支持 errorBuilder', 'fit: BoxFit.cover 裁剪填充'],
    requiredTokens: ['Image.network', 'width: 200', 'height: 200', 'BoxFit.cover', 'errorBuilder'],
  ),
  'flutter-17': PracticeSpec(
    lessonId: 'flutter-17',
    title: 'DevTools / 性能',
    requirement:
        '实现一个长列表（1000 条），使用 ListView.builder 按需构建，'
        '并在每行使用 const 组件，避免不必要的重建。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView.builder(
          itemCount: 1000,
          itemBuilder: (context, index) => ListTile(title: Text('Row $index')),
        ),
      ),
    );
  }
}
''',
    hints: ['ListView.builder 只构建可见区域', '避免在 itemBuilder 外创建大对象'],
    requiredTokens: ['ListView.builder', 'itemCount: 1000', 'itemBuilder'],
    strict: true,
    forbiddenTokens: ['ListView('],
  ),
  'flutter-18': PracticeSpec(
    lessonId: 'flutter-18',
    title: '平台特定代码',
    requirement:
        '使用 MethodChannel 定义一个名为 practice/channel 的通道，'
        '调用 getPlatformVersion 方法并把结果展示在页面上。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: ChannelPage());
}

class ChannelPage extends StatefulWidget {
  const ChannelPage({super.key});

  @override
  State<ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends State<ChannelPage> {
  static const channel = MethodChannel('practice/channel');
  String version = '未获取';

  Future<void> load() async {
    try {
      final result = await channel.invokeMethod<String>('getPlatformVersion');
      setState(() => version = result ?? '未知');
    } on PlatformException catch (e) {
      setState(() => version = '失败：${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(version),
            ElevatedButton(onPressed: load, child: const Text('获取')),
          ],
        ),
      ),
    );
  }
}
''',
    hints: ['MethodChannel 需要唯一通道名', 'invokeMethod 是异步的', '捕获 PlatformException'],
    requiredTokens: ['MethodChannel', 'invokeMethod', 'PlatformException', 'flutter/services'],
  ),
  'flutter-19': PracticeSpec(
    lessonId: 'flutter-19',
    title: '测试',
    requirement:
        '编写一个 widget test：启动包含 Text("Hello") 的组件，'
        '并用 expect(find.text("Hello"), findsOneWidget) 断言。',
    starter: r'''import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('显示 Hello', (tester) async {
    // TODO: pumpWidget 并断言
  });
}
''',
    answer: r'''import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('显示 Hello', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('Hello')));
    expect(find.text('Hello'), findsOneWidget);
  });
}
''',
    hints: ['testWidgets 提供 WidgetTester', 'pumpWidget 挂载组件', 'expect + find.text'],
    requiredTokens: ['testWidgets', 'pumpWidget', 'expect', 'findsOneWidget'],
  ),
  'flutter-20': PracticeSpec(
    lessonId: 'flutter-20',
    title: '打包与发布',
    requirement:
        '实现一个 App 信息卡片：显示应用名、版本号「1.0.0」和构建号「1」，'
        '使用 const 组件，方便发布前检查配置。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: InfoPage());
  }
}

class InfoPage extends StatelessWidget {
  const InfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('SLIPE Practice'),
            Text('版本 1.0.0 (1)'),
          ],
        ),
      ),
    );
  }
}
''',
    hints: ['页面与信息都可用 const', '版本号与构建号写在 UI 上便于核对'],
    requiredTokens: ['const MaterialApp', '版本 1.0.0', 'SLIPE Practice'],
    strict: true,
  ),
  'flutter-21': PracticeSpec(
    lessonId: 'flutter-21',
    title: '最佳实践',
    requirement:
        '把页面拆成至少两个 Widget（Page 与 ItemCard），使用 const 构造，'
        '禁止在 build 中使用 print，列表使用 ListView.builder。',
    starter: _defaultStarter,
    answer: r'''import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: PracticePage());
  }
}

class PracticePage extends StatelessWidget {
  const PracticePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView.builder(
        itemCount: 10,
        itemBuilder: (context, index) => ItemCard(index: index),
      ),
    );
  }
}

class ItemCard extends StatelessWidget {
  const ItemCard({super.key, required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    return ListTile(title: Text('Item $index'));
  }
}
''',
    hints: ['拆分出 ItemCard 组件', '能 const 的构造尽量 const', '列表使用 ListView.builder'],
    requiredTokens: ['class ItemCard', 'ListView.builder', 'const PracticePage'],
    forbiddenTokens: ['print('],
    strict: true,
  ),
};
