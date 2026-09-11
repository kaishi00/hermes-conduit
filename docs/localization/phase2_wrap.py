#!/usr/bin/env python3
"""Phase 2: classify string-literal occurrences and (optionally) wrap String-context
literals with String(localized:). v2 — global-risk pass, rawValue/Siri exclusions.

Usage: python3 phase2_wrap.py plan|apply
"""
import json, re, sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path('/Users/stardo/Project/hermes-conduit')
APP = ROOT / 'Conduit'
DRAFT = json.load(open(ROOT / 'docs/localization/conduit-zh-draft.json'))
PLAN_OUT = ROOT / 'docs/localization/phase2-plan.json'

AUTO_APIS = [
    'Text(', 'Button(', 'Label(', 'Toggle(', 'Picker(', 'Menu(', 'NavigationLink(',
    'Section(', 'TextField(', 'SecureField(', 'Stepper(', 'LabeledContent(',
    'DisclosureGroup(', 'GroupBox(', 'ShareLink(', 'Link(', 'alert(', 'Alert(',
    'confirmationDialog(', '.navigationTitle(', '.navigationSubtitle(', '.badge(',
    '.accessibilityLabel(', '.accessibilityHint(', '.accessibilityValue(', '.help(',
    'ProgressView(', 'ContentUnavailableView(', '.searchable(', 'Tab(', 'TabView(',
    'IntentDescription(', 'DialogIntent(', 'IntentDialog(',
]
# 前一个 token 命中 → 身份比较/模式匹配, 不可包裹
RISK_PREV_TOKENS = ('==', '!=', '===', '!==', 'case', 'forKey:', '.contains(', 'contains(',
                    'hasPrefix(', 'hasSuffix(', 'firstIndex(of:', 'replaceOccurrences')
# 前文窗口命中 → Siri/存储/键名等特殊语境
RISK_WINDOW = ('phrases:', 'shortTitle:', 'AppShortcut(', 'suggestedInvocationPhrase',
               '(rawValue', 'setAlternateIconName', 'forKey:', 'logger.', 'Logger(', 'os_log(')
RAW_VALUE_TAIL = re.compile(r'(?:case\s+\w+|default)\s*=\s*$')
INTERP = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')
STR_LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
WS = re.compile(r'\s+')
# (文件后缀, 行号) 显式排除: 该字面量是系统标识符而非显示文案
EXCLUDE = {('Models/AppIconChoice.swift', 17)}  # alternateIconName 三元分支(图标标识符)

def blank_comments(src: str) -> str:
    """字符串感知地剥掉 // 与 /* */ 注释(等长空格替换, 保偏移)。"""
    out = list(src); i, n, in_str = 0, len(src), False
    while i < n:
        c = src[i]
        if in_str:
            if c == '\\': i += 2 if i + 1 < n else 1; continue  # 跳过转义, 保留字符
            if c == '"': in_str = False
            i += 1; continue
        if c == '"': in_str = True; i += 1; continue
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out[i] = ' '; i += 1
            continue
        if c == '/' and i + 1 < n and src[i + 1] == '*':
            j = i
            while j + 1 < n and not (src[j] == '*' and src[j + 1] == '/'):
                if src[j] != '\n': out[j] = ' '
                j += 1
            i = j + 2; continue
        i += 1
    return ''.join(out)

def clean_literal(s: str) -> str:
    s = INTERP.sub(' X ', s)
    s = s.replace('\\n', ' ').replace('\\"', '"').replace("\\'", "'")
    return WS.sub(' ', s).strip()

def zh_of(cleaned: str):
    item = DRAFT.get(cleaned)
    if item and item.get('zh') and item.get('confidence') in ('exact', 'review'):
        return item['zh']
    return None

def occurrences(path: Path):
    src = path.read_text(errors='replace')
    nodata = blank_comments(src)
    occs = []
    for m in STR_LIT.finditer(nodata):
        raw = m.group(1)
        open_q, close_q = m.start(1) - 1, m.end(1)
        pre = nodata[max(0, open_q - 140):open_q]
        post = nodata[close_q + 1:close_q + 40]
        pre_tail = pre.rstrip()
        occs.append({'raw': raw, 'open': open_q, 'close': close_q,
                     'pre_tail': pre_tail, 'pre': pre, 'next': post.lstrip()[:1],
                     'line': src.count('\n', 0, open_q) + 1})
    return src, nodata, occs

def classify_file(path: Path, risky_raws: set):
    src, nodata, occs = occurrences(path)
    decisions = []
    for o in occs:
        raw, pre_tail, next_ch = o['raw'], o['pre_tail'], o['next']
        cleaned = clean_literal(raw)
        zh = zh_of(cleaned)
        rec = {'file': str(path), 'start': o['open'], 'end': o['close'] + 1, 'raw': raw,
               'cleaned': cleaned, 'zh': zh, 'line': o['line']}
        def skip(cat): rec['cat'] = cat; decisions.append(rec); return True
        if pre_tail.endswith('#') or re.search(r'#"', pre_tail[-3:] + '"'):
            skip('skip:raw-string'); continue
        if 'String(localized:' in pre_tail[-60:]:
            skip('skip:already-wrapped'); continue
        if nodata[max(0, o['open']-2):o['open']] == '""' or nodata[o['close']+1:o['close']+3] == '""':
            skip('skip:multiline'); continue
        if not next_ch: skip('skip:eof'); continue
        if '\\(' in raw and raw.count('(') != raw.count(')'):
            skip('skip:fragment'); continue
        if zh is None: skip('skip:no-zh'); continue
        if (str(path).split('Conduit/', 1)[-1], o['line']) in EXCLUDE:
            skip('skip:explicit-exclude'); continue
        if raw in risky_raws: skip('skip:identity-risk'); continue
        if zh.strip() == raw.strip(): skip('skip:identity-zh'); continue
        if '.accessibilityIdentifier' in pre_tail[-60:]:
            skip('skip:identifier'); continue
        if any(w in o['pre'] for w in RISK_WINDOW):
            skip('skip:window-risk'); continue
        if RAW_VALUE_TAIL.search(pre_tail):
            skip('skip:raw-value'); continue
        prev_tok = pre_tail
        for t in RISK_PREV_TOKENS:
            idx = pre_tail.rfind(t)
            if idx != -1 and pre_tail[idx + len(t):].strip() == '':
                skip('skip:comparison'); break
        else:
            prev_ch = pre_tail[-1] if pre_tail else ''
            if prev_ch == '+':
                rec['cat'] = 'wrap'; decisions.append(rec); continue
            if next_ch == ':' and prev_ch != '?':
                skip('skip:dict-key'); continue
            if 'Text(verbatim:' in pre_tail[-30:]:
                skip('skip:verbatim'); continue
            if any(pre_tail.endswith(a) for a in AUTO_APIS) and next_ch in (')', ',', ' ', ':'):
                rec['cat'] = 'auto'; decisions.append(rec); continue
            rec['cat'] = 'wrap'; decisions.append(rec)
    return decisions, src

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'plan'
    files = sorted(APP.rglob('*.swift'))
    # pass 1: 全局风险 — raw 在任意出现点被比较/匹配 → 整串排除
    risky = set()
    for f in files:
        _, _, occs = occurrences(f)
        for o in occs:
            pre_tail = o['pre_tail']
            hit = any(pre_tail.rfind(t) != -1 and pre_tail[pre_tail.rfind(t) + len(t):].strip() == ''
                      for t in RISK_PREV_TOKENS)
            hit = hit or any(w in o['pre'] for w in RISK_WINDOW) or bool(RAW_VALUE_TAIL.search(pre_tail))
            if hit: risky.add(o['raw'])
    print(f'全局风险串(整串排除): {len(risky)} 个')
    all_dec, sources = [], {}
    for f in files:
        dec, src = classify_file(f, risky)
        all_dec.extend(dec); sources[str(f)] = src
    stats = Counter(d['cat'] for d in all_dec)
    print('== 分类统计 ==')
    for k, v in stats.most_common(): print(f'  {k}: {v}')
    wraps = [d for d in all_dec if d['cat'] == 'wrap']
    per_file = Counter(Path(d['file']).name for d in wraps)
    print(f'\n== wrap 共 {len(wraps)} 处 (插值 {sum(1 for d in wraps if chr(92)+"(" in d["raw"])}) top10 ==')
    for f, n in per_file.most_common(10): print(f'  {n:4d}  {f}')
    by_file = defaultdict(list)
    for d in wraps: by_file[d['file']].append(d)
    overlap = sum(1 for f, ds in by_file.items()
                  for a, b in zip(sorted(ds, key=lambda x: x['start']), sorted(ds, key=lambda x: x['start'])[1:])
                  if b['start'] < a['end'])
    print(f'重叠冲突: {overlap}')
    if mode == 'apply':
        changed = 0
        for f, ds in by_file.items():
            src = sources[f]
            for d in sorted(ds, key=lambda x: -x['start']):
                src = src[:d['start']] + f'String(localized: {src[d["start"]:d["end"]]})' + src[d['end']:]
                changed += 1
            Path(f).write_text(src)
        print(f'\nAPPLIED: {changed} 处 → {len(by_file)} 个文件')
    else:
        PLAN_OUT.write_text(json.dumps(
            [{'file': d['file'], 'line': d['line'], 'raw': d['raw'], 'zh': d['zh']}
             for d in wraps], ensure_ascii=False, indent=1))
        print(f'\n计划已写入 {PLAN_OUT}')
        susp = [d for d in wraps if len(d['raw']) <= 6 or re.fullmatch(r'[a-z][a-z0-9 _/-]*', d['raw'])]
        print(f'\n== 残留可疑 wrap {len(susp)} 处 ==')
        for d in susp[:25]:
            print(f"  {Path(d['file']).name}:{d['line']} {d['raw']!r} → {d['zh'][:16]!r}")

if __name__ == '__main__':
    main()
