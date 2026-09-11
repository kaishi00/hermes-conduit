#!/usr/bin/env python3
"""Phase 3: generate Conduit/Localizable.xcstrings from the zh draft.

Key derivation per source occurrence:
  plain literal  → key = runtime string (unescaped)
  interpolated   → key = pattern (\\(expr) → %lld for int-ish exprs, else %@);
                   missing the exact specifier only falls back to English (safe).
zh values: {0}/{1} → %@ / positional %1$@…
"""
import json, re, sys
from pathlib import Path

ROOT = Path('/Users/stardo/Project/hermes-conduit')
APP = ROOT / 'Conduit'
DRAFT = json.load(open(ROOT / 'docs/localization/conduit-zh-draft.json'))
OUT = APP / 'Localizable.xcstrings'

INTERP = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')
STR_LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
WS = re.compile(r'\s+')
INT_HINT = re.compile(r'(?:^|(?<=[a-z0-9]))(Count|Total|Num|Index|Seconds?|Percent|Age|Turns?|Max|Min|Size|Length|Offset|Depth|Retries|Remaining|Left)(?=$|[_A-Z])')
INT_NAMES = re.compile(r'^(?:pid|PID|port|status|code|version|build|step|number|count|total|index|seconds|percent|occurrence|pageSize|offset|active|updated|n|row|column|line|item|piece|cell)$')

def _is_int_expr(expr: str) -> bool:
    e = expr.strip()
    if ', privacy' in e: e = e.split(',')[0].strip()
    if INT_HINT.search(e) or '.count' in e or 'Int(' in e: return True
    return bool(INT_NAMES.match(e.split('.')[-1].strip()))

def clean_literal(s):
    s = INTERP.sub(' X ', s)
    s = s.replace('\\n', ' ').replace('\\"', '"').replace("\\'", "'")
    return WS.sub(' ', s).strip()

def unescape(s):
    return (s.replace('\\n', '\n').replace('\\"', '"')
             .replace("\\'", "'").replace('\\t', '\t'))

def pattern_key(raw):
    """raw 源码字面量 → 本地化 pattern key (按出现顺序映射占位符)。"""
    out, specs, idx = [], [], [0]
    def repl(m):
        expr = m.group(0)[2:-1]
        i = idx[0]; idx[0] += 1
        spec = '%lld' if _is_int_expr(expr) else '%@'
        specs.append(spec)
        return spec
    key = INTERP.sub(repl, raw)
    return unescape(key), specs

def zh_convert(zh, specs):
    """{0}/{1} → 说明符; 多参数用位置说明符。"""
    n = len(specs)
    if n == 0:
        return zh
    if n == 1:
        return zh.replace('{0}', specs[0])
    return re.sub(r'\{(\d+)\}', lambda m: '%' + str(int(m.group(1)) + 1) + '$' + specs[int(m.group(1))][1:], zh)

def build():
    catalog = {'sourceLanguage': 'en', 'strings': {}, 'version': '1.0'}
    stats = {'plain': 0, 'interp': 0, 'no-occurrence': 0, 'code-in-zh': 0}
    interp_log = []
    for cleaned, item in DRAFT.items():
        zh = item.get('zh')
        if not zh or item.get('confidence') not in ('exact', 'review'):
            continue
        if '\\(' in zh:  # Swift 代码嵌在 zh 里 (截断插值片段), 无法进目录
            stats['code-in-zh'] += 1; continue
        # 找源码中对应 raw 形态
        raw_form = None
        for f in sorted(APP.rglob('*.swift')):
            src = f.read_text(errors='replace')
            for m in STR_LIT.finditer(src):
                if clean_literal(m.group(1)) == cleaned:
                    raw_form = m.group(1); break
            if raw_form: break
        if raw_form is None:
            stats['no-occurrence'] += 1; continue
        specs = []
        if '\\(' in raw_form:
            key, specs = pattern_key(raw_form)
            zh_v = zh_convert(zh, specs)
            stats['interp'] += 1
            interp_log.append({'key': key, 'zh': zh_v})
        else:
            key, zh_v = unescape(raw_form), zh
            stats['plain'] += 1
        entry = catalog['strings'].setdefault(key, {'localizations': {}})
        if specs:
            # 插值 key 补显式 en 条目: en 命中后走格式串路径(printf), 避免
            # key-miss 回退路径对数字做 locale 分组(4242 → 4,242 的行为回归)
            entry['localizations']['en'] = {'stringUnit': {'state': 'translated', 'value': key}}
        entry['localizations']['zh-Hans'] = {'stringUnit': {'state': 'translated', 'value': zh_v}}
    catalog['strings'] = dict(sorted(catalog['strings'].items()))
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, separators=(',', ' : ')))
    print(f"目录生成: {len(catalog['strings'])} 条 → {OUT.name}")
    print(f"  纯字面量 {stats['plain']} / 插值 {stats['interp']} / 源码未找到 {stats['no-occurrence']} / zh含代码 {stats['code-in-zh']}")
    (ROOT / 'docs/localization/phase3-interp-keys.json').write_text(
        json.dumps(interp_log, ensure_ascii=False, indent=1))
    print(f"插值 key 清单 → docs/localization/phase3-interp-keys.json ({len(interp_log)} 条, 需运行时核对)")

if __name__ == '__main__':
    build()
