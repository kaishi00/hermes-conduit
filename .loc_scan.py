#!/usr/bin/env python3
"""Scan Swift sources for user-facing strings to size up localization work."""
import json, re, sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).parent
UI_API = re.compile(
    r'(Text|Button|Label|Toggle|Picker|TextField|SecureField|Stepper|Slider|Menu|'
    r'NavigationLink|ShareLink|EditButton|Link|LabeledContent|Section|alert|'
    r'confirmationDialog|navigationTitle|navigationBarTitleDisplayMode|accessibilityLabel|'
    r'accessibilityHint|accessibilityValue|accessibilityText|placeholder|suggestedInvocationPhrase)'
    r'\s*[:(]\s*$'
)
KWARG = re.compile(r'\b(title|message|label|placeholder|prompt|name|headline|subtitle|footer|'
                   r'description|text|instructions|reason|summary|displayName)\s*:\s*$')
NOISE_API = re.compile(
    r'(logger|log|Log|print|debugPrint|os_log|Logger|NSLog|dump|assert|'
    r'precondition|fatalError|font|Font|foregroundStyle|Color|Image|systemName|'
    r'for|in|of|id|key|notification|selector|scheme|host|path|header|field|'
    r'mimeType|uti|identifier|bundle|UserDefaults|sound|symbol|commandName|'
    r'sorting|json|jsonrpc|method|error_code|event)\s*[:(]\s*$')

STR_LIT = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
ML_STR = re.compile(r'"""(.*?)"""', re.S)
LINE_COMMENT = re.compile(r'//[^\n]*')
BLOCK_COMMENT = re.compile(r'/\*.*?\*/', re.S)
INTERP = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')
WORDS = re.compile(r'[A-Za-z][A-Za-z\'’\-]*')

def strip_comments(src: str) -> str:
    src = BLOCK_COMMENT.sub(' ', src)
    # keep string contents intact: only strip // that are not inside strings is hard;
    # approximation: strings rarely contain '//' plus real prose; URLs lost -> acceptable
    return src

def clean_literal(s: str) -> str:
    s = INTERP.sub(' X ', s)
    s = s.replace('\\n', ' ').replace('\\"', '"').replace("\\'", "'")
    return re.sub(r'\s+', ' ', s).strip()

def is_prose(s: str) -> bool:
    words = WORDS.findall(s)
    if len(words) < 2:
        return False
    letters = sum(len(w) for w in words)
    if letters < 6:
        return False
    # reject technical-looking: paths, urls, keys
    if re.search(r'[/_:{}.@#=<>]|https?|\.swift|\.json|\.png', s):
        return False
    return True

def scan_file(path: Path):
    src = strip_comments(path.read_text(errors='replace'))
    results = []  # (kind, literal, offset)
    ml_spans = []
    def ml_repl(m):
        ml_spans.append((m.start(), m.end()))
        results.append(('multiline', clean_literal(m.group(1)), m.start()))
        return ' ' * (m.end() - m.start())
    src = ML_STR.sub(ml_repl, src)
    for m in STR_LIT.finditer(src):
        lit = clean_literal(m.group(1))
        if not lit:
            continue
        prefix = src[max(0, m.start()-90):m.start()]
        prefix_tail = re.sub(r'\s+', ' ', prefix).strip()
        last_line = prefix_tail.rsplit(' ', 0)  # whole tail is fine for regex $
        if UI_API.search(prefix_tail + ' ') or UI_API.search(prefix_tail):
            results.append(('ui', lit, m.start()))
        elif KWARG.search(prefix_tail) and is_prose(lit):
            results.append(('ui', lit, m.start()))
        else:
            # strip preceding API name to test log-context
            tail = prefix_tail
            if re.search(r'\b(logger|log|print|debugPrint|os_log|NSLog|dump|Log)\b', tail.split(',')[-1] if ',' in tail else tail[-40:]):
                results.append(('log', lit, m.start()))
            else:
                results.append(('plain', lit, m.start()))
    return results

def module_of(rel: str) -> str:
    parts = rel.split('/')
    if parts[0] == 'Conduit':
        return parts[1] if len(parts) > 2 else '(root)'
    if parts[0] in ('ConduitTests', 'ConduitUITests'):
        return parts[0]
    return parts[0]

def main():
    summary = {}
    per_mod_ui = defaultdict(set)       # unique ui literals per module
    per_mod_prose = defaultdict(set)    # unique prose-ish literals (non-log)
    all_ui = set(); all_ui_occ = 0
    all_prose = set()
    ui_words = 0; prose_words = 0
    per_file_ui = defaultdict(int)
    for swift in sorted(ROOT.rglob('*.swift')):
        rel = str(swift.relative_to(ROOT))
        if rel.startswith(('scripts/', 'docs/', '.github/')):
            continue
        for kind, lit, _ in scan_file(swift):
            mod = module_of(rel)
            if kind == 'ui':
                per_mod_ui[mod].add(lit); all_ui.add(lit); all_ui_occ += 1
                ui_words += len(WORDS.findall(lit))
                per_file_ui[rel] += 1
            elif kind == 'plain' and is_prose(lit):
                per_mod_prose[mod].add(lit); all_prose.add(lit)
                prose_words += len(WORDS.findall(lit))
    def wcount(items): return sum(len(WORDS.findall(s)) for s in items)
    print('== UI-API 挂钩字符串 (唯一) ==')
    for mod in sorted(set(per_mod_ui) | set(per_mod_prose)):
        u, p = per_mod_ui.get(mod, set()), per_mod_prose.get(mod, set())
        print(f'{mod:20s} ui={len(u):5d} ({wcount(u):5d}w)   prose={len(p):5d} ({wcount(p):5d}w)')
    print(f'\nUI 合计: 唯一 {len(all_ui)} 条 / 出现 {all_ui_occ} 次 / {ui_words} 词')
    print(f'非API prose(疑似服务层文案): 唯一 {len(all_prose)} 条 / {prose_words} 词')
    print('\n== UI 字符串最多的 15 个文件 ==')
    for f, n in sorted(per_file_ui.items(), key=lambda kv: -kv[1])[:15]:
        print(f'{n:5d}  {f}')
    print('\n== UI 字符串样例(每模块前3) ==')
    for mod in ['Views', 'Services', 'Voice', 'Models', 'Intents', '(root)']:
        sample = sorted(per_mod_ui.get(mod, []))[:3]
        print(f'--- {mod}:')
        for s in sample:
            print(f'    {s[:90]}')
    # save full list
    out = {'ui_unique': sorted(all_ui), 'prose_unique': sorted(all_prose)}
    (ROOT / '.loc-scan.json').write_text(json.dumps(out, ensure_ascii=False, indent=1))

if __name__ == '__main__':
    main()
