#!/usr/bin/env python3
"""校验翻译子代理产出。

用法:
  python3 docs/localization/check_translations.py <result.json> [--base conduit-zh-draft.json]

检查项:
  1. schema 合法: {"en": {"zh": str|null, "confidence": "exact|review|none", "notes": str?}}
  2. 译文含 CJK（zh 非 null 时）
  3. 占位符守恒: en 的插值/占位符数量 == zh 的占位符数量
  4. 长度告警: zh 有效字符数 > en 词数 × 2.4（疑似翻译冗长）
  5. 英文残留: zh 中出现连续英文单词（白名单: 专名/技术名词）
  6. 与初稿冲突: 同 en 在 base 中已有 exact 译文且不同（提示人工仲裁）
退出码: 有 error 为 1，仅 warning 为 0。
"""
import json, re, sys
from pathlib import Path

WHITELIST = {
    'Conduit', 'Hermes', 'Whisper', 'Face ID', 'Touch ID', 'Siri', 'Tailscale',
    'Cloudflare', 'WebSocket', 'YAML', 'API', 'URL', 'ID', 'iOS', 'iPadOS',
    'Markdown', 'PCM', 'SF', 'MiMo', 'OpenAI', 'Groq', 'SSH', 'VPN', 'JSON',
}
CJK = re.compile(r'[\u4e00-\u9fff]')
EN_WORD = re.compile(r'[A-Za-z][A-Za-z\'-]*')
PLACEHOLDER = re.compile(r'\{\d*\}|%@|%d|%@|\{[a-zA-Z_][\w]*\}')

def norm_placeholders(s: str) -> int:
    # conduit 扫描器把插值标成独立词 X；译文里可能是 {} {0} %@ 等
    xmarks = len(re.findall(r'(?<![A-Za-z])X(?![A-Za-z])', s))
    return len(PLACEHOLDER.findall(s)) + xmarks

def residue_words(zh: str):
    words = EN_WORD.findall(zh)
    out, i = [], 0
    while i < len(words):
        j = i
        while j + 1 < len(words) and f'{words[j]} {words[j+1]}' in WHITELIST:
            j += 1
        phrase = ' '.join(words[i:j+1])
        if phrase not in WHITELIST and len(phrase) > 1:
            out.append(phrase)
        i = j + 1
    return out

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    result = json.loads(Path(sys.argv[1]).read_text())
    base_path = Path(sys.argv[sys.argv.index('--base')+1]) if '--base' in sys.argv else None
    base = json.loads(base_path.read_text()) if base_path else {}
    errors, warnings = [], []
    for en, item in result.items():
        tag = f'{en[:44]!r}'
        if not (isinstance(item, dict) and {'zh', 'confidence'} <= item.keys()):
            errors.append(f'{tag}: schema 不合法'); continue
        zh, conf = item.get('zh'), item.get('confidence')
        if conf not in ('exact', 'review', 'none'):
            errors.append(f'{tag}: confidence 必须是 exact/review/none'); continue
        if conf == 'none':
            if zh not in (None, ''): errors.append(f'{tag}: confidence=none 但 zh 非空')
            continue
        if not zh:
            errors.append(f'{tag}: confidence={conf} 但 zh 为空'); continue
        if not CJK.search(zh):
            errors.append(f'{tag}: 译文无中文 → {zh[:30]!r}')
        pe, pz = norm_placeholders(en), norm_placeholders(zh)
        if pe != pz:
            errors.append(f'{tag}: 占位符不守恒 en={pe} zh={pz} → {zh[:40]!r}')
        en_words = len(EN_WORD.findall(en))
        zh_cjk = len(CJK.findall(zh))  # 只统计汉字，数字/标点/占位符不计
        if en_words and zh_cjk > en_words * 2.6:
            warnings.append(f'{tag}: 译文偏长 ({zh_cjk}汉字/en {en_words}词) → {zh[:40]!r}')
        for w in residue_words(zh):
            if len(w.split()) >= 2 or (len(w) > 3 and w not in {x for x in WHITELIST}):
                warnings.append(f'{tag}: 疑似英文残留 {w!r} → {zh[:40]!r}')
        if base.get(en, {}).get('confidence') == 'exact' and base[en]['zh'] != zh:
            warnings.append(f'{tag}: 与初稿 exact 译文不同 → 初稿 {base[en]["zh"]!r} / 本次 {zh!r}')
    print(f'共 {len(result)} 条: {len(errors)} error / {len(warnings)} warning')
    for e in errors: print(f'  [E] {e}')
    for w in warnings[:30]: print(f'  [W] {w}')
    sys.exit(1 if errors else 0)

if __name__ == '__main__':
    main()
