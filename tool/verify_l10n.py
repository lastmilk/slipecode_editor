#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L10n 三语一致性校验（临时脚本，校验后删除）"""
import re
import sys

DICT = '/workspace/lib/l10n/app_localizations.dart'
FILES = [
    '/workspace/lib/screens/build_screen.dart',
    '/workspace/lib/screens/account_screen.dart',
    '/workspace/lib/screens/create_project_screen.dart',
    '/workspace/lib/screens/policy_screen.dart',
    '/workspace/lib/screens/ai_chat_screen.dart',
    '/workspace/lib/providers/terminal_provider.dart',
]

STR_RE = re.compile(r"'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"")
KEY_RE = re.compile(r"^\w[\w.]*$")


def strip_interp(s):
    """去掉 ${...} 插值（字典值不含插值，防御性处理）。"""
    return re.sub(r'\$\{[^}]*\}', '', s)


def unquote(tok):
    body = tok[1:-1]
    out = []
    i = 0
    while i < len(body):
        c = body[i]
        if c == '\\' and i + 1 < len(body):
            nxt = body[i + 1]
            mapping = {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\',
                       "'": "'", '"': '"', '$': '$'}
            if nxt in mapping:
                out.append(mapping[nxt])
                i += 2
                continue
            out.append(c)
            i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def split_toplevel(tokens):
    """把字符串 token 序列按顶层逗号分组。tokens 为 ('str'|'comma', text)。"""
    groups, cur, depth = [], [], 0
    for kind, text in tokens:
        if kind == 'comma':
            if depth == 0:
                if cur:
                    groups.append(cur)
                    cur = []
                continue
        elif text in ('{', '[', '('):
            depth += 1
        elif text in ('}', ']', ')'):
            depth -= 1
        cur.append((kind, text))
    if cur:
        groups.append(cur)
    return groups


def parse_dict(src):
    """解析 L10n._values：返回 {lang: OrderedDict{key: value}}。"""
    m = re.search(r'_values\s*=\s*\{', src)
    if not m:
        print('FATAL: _values not found')
        sys.exit(1)
    start = m.end()
    depth = 1
    i = start
    in_str = None
    while i < len(src) and depth > 0:
        c = src[i]
        if in_str:
            if c == '\\':
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ('"', "'"):
            in_str = c
        elif c == '/' and i + 1 < len(src) and src[i + 1] == '/':
            j = src.find('\n', i)
            i = j if j != -1 else len(src)
            continue
        elif c in '{[(':
            depth += 1
        elif c in '}])':
            depth -= 1
        i += 1
    block = src[start:i - 1]

    tokens = []
    pos = 0
    for sm in STR_RE.finditer(block):
        gap = block[pos:sm.start()]
        for ch in gap:
            if ch in '{[()]}':
                tokens.append(('brace', ch))
            elif ch == ',':
                tokens.append(('comma', ','))
        tokens.append(('str', sm.group(0)))
        pos = sm.end()
    for ch in block[pos:]:
        if ch in '{[()]}':
            tokens.append(('brace', ch))
        elif ch == ',':
            tokens.append(('comma', ','))

    # 顶层结构：'zh' : { ... }, 'zhHant' : { ... }, 'en' : { ... }
    langs = {}
    cur_lang = None
    depth = 0
    expect = 'lang'
    pending_key = None
    for kind, text in tokens:
        if kind == 'brace':
            if text == '{':
                depth += 1
                if depth == 1 and expect == 'lang' and pending_key:
                    cur_lang = unquote(pending_key)
                    langs[cur_lang] = {}
                    pending_key = None
                    expect = 'entry'
                    continue
                if depth == 2 and expect == 'entry':
                    continue
            else:
                depth -= 1
                if depth == 0:
                    cur_lang = None
                    expect = 'lang'
                continue
        if depth == 1 and kind == 'str' and expect == 'lang':
            pending_key = text
        elif depth == 2 and cur_lang and kind == 'str':
            if pending_key is None:
                pending_key = text
            else:
                langs[cur_lang][unquote(pending_key)] = unquote(text)
                pending_key = None
    return langs


def placeholders(value):
    return sorted(re.findall(r'\{(\w+)\}', value))


def main():
    with open(DICT, encoding='utf-8') as f:
        src = f.read()
    langs = parse_dict(src)
    print('parsed langs:', {k: len(v) for k, v in langs.items()})

    zh = langs.get('zh', {})
    zh_hant = langs.get('zhHant', {})
    en = langs.get('en', {})

    ok = True

    # 1. key 集合一致性
    sets = {'zh': set(zh), 'zhHant': set(zh_hant), 'en': set(en)}
    names = list(sets)
    for a in range(len(names)):
        for b in range(a + 1, len(names)):
            na, nb = names[a], names[b]
            only_a = sets[na] - sets[nb]
            only_b = sets[nb] - sets[na]
            if only_a or only_b:
                ok = False
                print(f'MISMATCH {na} vs {nb}: only-{na}={sorted(only_a)} only-{nb}={sorted(only_b)}')
    print('key parity across dicts:', 'OK' if ok else 'FAIL')

    # 2. 占位符一致性
    ph_ok = True
    common_keys = set(zh) & set(zh_hant) & set(en)
    for k in sorted(common_keys):
        ph = {placeholders(zh[k]), placeholders(zh_hant[k]), placeholders(en[k])}
        if len(ph) > 1:
            ph_ok = False
            print(f'PLACEHOLDER MISMATCH {k}: zh={placeholders(zh[k])} zhHant={placeholders(zh_hant[k])} en={placeholders(en[k])}')
    print('placeholder parity:', 'OK' if ph_ok else 'FAIL')
    if not ph_ok:
        ok = False

    # 3. 改动文件中的 t() key 是否都存在
    all_defined = set(zh) & set(zh_hant) & set(en)
    used = {}
    for path in FILES:
        with open(path, encoding='utf-8') as f:
            code = f.read()
        code_nc = re.sub(r"//[^\n]*", '', code)
        keys = re.findall(r"\bt\(\s*'([\w.]+)'", code_nc)
        used[path] = sorted(set(keys))
        missing = [k for k in used[path] if k not in all_defined]
        if missing:
            ok = False
            print(f'MISSING in dicts ({path}): {missing}')
    total_used = sorted(set().union(*used.values()))
    print('distinct t() keys used in 6 files:', len(total_used))

    # 4. 字典 key 命名合法性 & 值非空
    for lang, d in langs.items():
        for k, v in d.items():
            if not KEY_RE.match(k):
                ok = False
                print(f'BAD KEY ({lang}): {k!r}')
            if v == '' and k not in ():
                print(f'EMPTY VALUE ({lang}): {k!r}')

    # 5. 本轮新增 key 数（相对 git HEAD 不可靠，改为列出新增分区 key 并计数）
    new_prefix_counts = {}
    for k in zh:
        if k.startswith(('build.', 'account.', 'create.', 'ai.')):
            new_prefix_counts.setdefault(k.split('.')[0], []).append(k)
    for p, ks in sorted(new_prefix_counts.items()):
        print(f'new-domain {p}: {len(ks)} keys')
    print('policy.and etc added:',
          [k for k in zh if k in ('policy.and', 'policy.userAgreement', 'policy.privacyPolicy',
                                  'policy.loadFailed', 'policy.notPublished', 'policy.version',
                                  'policy.updatedAt', 'terminal.unsupportedLog')])
    new_total = sum(len(v) for v in new_prefix_counts.values()) + 8
    print('estimated new keys this round:', new_total)

    print('OVERALL:', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
