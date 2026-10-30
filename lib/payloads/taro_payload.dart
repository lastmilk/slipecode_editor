import 'package:flutter/material.dart';

import 'project_payload.dart';

/// 小程序载荷：Taro
class TaroPayload extends ProjectPayload {
  const TaroPayload();

  @override
  String get id => 'taro';

  @override
  String get name => '小程序（Taro）';

  @override
  String get description => 'Taro + React 的微信小程序';

  @override
  IconData get icon => Icons.apps;

  @override
  String get projectNameHint => 'my_taro_app';

  @override
  String get defaultOrg => 'com.example';

  @override
  String get defaultLanguage => 'typescript';

  @override
  Map<String, String> get languageByExtension => const {
        'tsx': 'typescript',
        'ts': 'typescript',
        'js': 'javascript',
        'jsx': 'javascript',
        'scss': 'css',
        'css': 'css',
        'json': 'json',
        'md': 'markdown',
        'yml': 'yaml',
        'yaml': 'yaml',
      };

  @override
  List<PayloadBuildType> get buildTypes => const [
        PayloadBuildType('release', '小程序包', '.zip'),
      ];

  @override
  String get workflowContent => r'''
name: SlipCode Build

on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      build_type:
        description: '构建类型'
        required: true
        type: choice
        default: 'release'
        options:
          - release

jobs:
  build-weapp:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install
        run: npm install --no-audit --no-fund

      - name: Build weapp
        run: npm run build:weapp

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: slipecode-${{ inputs.build_type || 'release' }}
          path: dist
          if-no-files-found: error
''';

  @override
  List<PayloadFile> templateFiles(String template) => const [
        PayloadFile.inline('package.json', _packageJson),
        PayloadFile.inline('project.config.json', _projectConfig),
        PayloadFile.inline('config/index.js', _configJs),
        PayloadFile.inline('tsconfig.json', _tsconfig),
        PayloadFile.inline('src/app.tsx', _appTsx),
        PayloadFile.inline('src/app.scss', _appScss),
        PayloadFile.inline('src/pages/index/index.tsx', _indexTsx),
        PayloadFile.inline('src/pages/index/index.config.ts', _indexConfigTs),
        PayloadFile.inline('src/pages/index/index.scss', _indexScss),
        PayloadFile.inline('README.md', _readme),
        PayloadFile.inline('.gitignore', _gitignore),
        PayloadFile.inline('.slipecode.json', _marker),
      ];

  static const String _packageJson = '''{
  "name": "{{PROJECT_NAME}}",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "build:weapp": "taro build --type weapp",
    "dev:weapp": "npm run build:weapp -- --watch"
  },
  "dependencies": {
    "@tarojs/components": "^3.6.35",
    "@tarojs/helper": "^3.6.35",
    "@tarojs/plugin-framework-react": "^3.6.35",
    "@tarojs/plugin-platform-weapp": "^3.6.35",
    "@tarojs/react": "^3.6.35",
    "@tarojs/runtime": "^3.6.35",
    "@tarojs/shared": "^3.6.35",
    "@tarojs/taro": "^3.6.35",
    "react": "^18.2.0",
    "react-dom": "^18.2.0"
  },
  "devDependencies": {
    "@babel/core": "^7.24.0",
    "@tarojs/cli": "^3.6.35",
    "@types/react": "^18.2.0",
    "sass": "^1.77.0",
    "typescript": "^5.4.0",
    "webpack": "5.91.0"
  }
}
''';

  static const String _projectConfig = '''{
  "miniprogramRoot": "dist/",
  "projectname": "{{PROJECT_NAME}}",
  "appid": "touristappid",
  "setting": {
    "urlCheck": false,
    "es6": false,
    "postcss": false,
    "minified": false
  },
  "compileType": "miniprogram"
}
''';

  static const String _configJs = '''const config = {
  projectName: '{{PROJECT_NAME}}',
  date: '2024-01-01',
  designWidth: 750,
  deviceRatio: {
    640: 2.34 / 2,
    750: 1,
    828: 1.81 / 2
  },
  sourceRoot: 'src',
  outputRoot: 'dist',
  plugins: [],
  framework: 'react',
  compiler: 'webpack5',
  mini: {
    postcss: {
      pxtransform: { enable: true, config: {} },
      cssModules: { enable: false }
    }
  }
};

module.exports = function (merge) {
  return merge({}, config);
};
''';

  static const String _tsconfig = '''{
  "compilerOptions": {
    "target": "ES2017",
    "module": "commonjs",
    "jsx": "react-jsx",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "moduleResolution": "node"
  },
  "include": ["src"]
}
''';

  static const String _appTsx = '''import { PropsWithChildren } from 'react';
import { useLaunch } from '@tarojs/taro';
import './app.scss';

function App({ children }: PropsWithChildren) {
  useLaunch(() => {
    console.log('App launched: {{PROJECT_NAME}}');
  });
  return children;
}

export default App;
''';

  static const String _appScss = '''page,
body {
  margin: 0;
  padding: 0;
  background: #f7f7f7;
  font-family: system-ui, -apple-system, sans-serif;
}
''';

  static const String _indexTsx = '''import { useState } from 'react';
import { View, Text, Button } from '@tarojs/components';
import './index.scss';

export default function Index() {
  const [count, setCount] = useState(0);

  return (
    <View className="index">
      <Text className="title">{{PROJECT_NAME}}</Text>
      <Text className="count">点击次数：{count}</Text>
      <Button className="btn" onClick={() => setCount(count + 1)}>
        点我
      </Button>
    </View>
  );
}
''';

  static const String _indexConfigTs = '''export default {
  navigationBarTitleText: '{{PROJECT_NAME}}'
};
''';

  static const String _indexScss = '''
.index {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 60px 24px;
}

.title {
  font-size: 40px;
  font-weight: 600;
}

.count {
  margin: 24px 0;
  font-size: 28px;
  color: #666;
}

.btn {
  background: #ff7a18;
  color: #111;
}
''';

  static const String _readme = '''# {{PROJECT_NAME}}

由 SLIPE（Taro 小程序 Payload）创建。

```bash
npm install
npm run build:weapp
```

构建产物在 `dist/`，用微信开发者工具导入项目根目录即可预览。
''';

  static const String _gitignore = '''node_modules/
dist/
.temp/
.rn_temp/
.swc/
.DS_Store
''';

  static const String _marker = '''{
  "project_name": "{{PROJECT_NAME}}",
  "payload": "taro",
  "created_by": "slipecode"
}
''';
}
