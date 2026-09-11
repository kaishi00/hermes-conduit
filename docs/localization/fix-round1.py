#!/usr/bin/env python3
"""Device-feedback round 1: wrap missed String-context literals + terminology fixes."""
import json, re
from pathlib import Path

ROOT = Path('/Users/stardo/Project/hermes-conduit')
APP = ROOT / 'Conduit'
DRAFT_P = ROOT / 'docs/localization/conduit-zh-draft.json'
DRAFT = json.load(open(DRAFT_P))

TABLE = {
 'Version': '版本', 'Server': '服务器', 'Reasoning': '思考强度', 'Used': '已用',
 'Capacity': '容量', 'Breakdown': '用量分布', 'About': '关于', 'Personality': '人格',
 'Timezone': '时区', 'Speed': '语速', 'Language': '语言', 'Endpoint': '端点',
 'Volume': '音量', 'File': '文件', 'Type': '类型', 'Size': '大小', 'Schedule': '排程',
 'Delivery': '送达', 'Prompt': '提示词', 'All': '全部', 'Local': '本地',
 'Sessions': '会话', 'Cron': '定时任务', 'Kanban': '看板', 'Reorder': '排序',
 'Move': '移动', 'Assign': '指派', 'More': '更多', 'Working…': '处理中…',
 'Pause': '暂停', 'Resume': '继续',
 'Server-side path for new workspaces.': '新工作区的服务器端路径。',
 'Default execution boundary.': '默认执行边界。',
 'Profile-wide default: manual asks every time; smart asks when risk warrants it; off is YOLO mode. When set to off, Hermes auto-approves everything and per-session YOLO toggles have no effect — that\'s a Hermes limitation, not a Conduit bug. To use per-session YOLO, set this to manual or smart.': '档案级默认：手动模式每次询问；智能模式按风险询问；关闭即 YOLO 模式。设为关闭时 Hermes 会自动批准一切，且各会话的 YOLO 开关不再生效——这是 Hermes 的限制，并非 Conduit 的问题。要使用会话级 YOLO，请将此项设为手动或智能。',
 'Hide detected credentials from tool output where possible.': '尽可能在工具输出中隐藏检测到的凭据。',
 'Permit tool access to private-network URLs.': '允许工具访问内网 URL。',
 'Provider used for long-term memory.': '用于长期记忆的提供方。',
 'Allow Hermes to retain relevant working memory.': '允许 Hermes 保留相关的工作记忆。',
 'Allow Hermes to maintain user preferences.': '允许 Hermes 维护用户偏好。',
 'Installed context-management engine.': '已安装的上下文管理引擎。',
 'Compress older context when the window becomes crowded.': '上下文窗口拥挤时压缩较早的内容。',
 'Fraction of the context window that starts compression.': '触发压缩的上下文窗口占比。',
 'Fraction retained after compression.': '压缩后保留的比例。',
 'Recent messages left intact by compression.': '压缩时保持原样的近期消息。',
 'Maximum child agents that can work at once.': '可同时工作的子智能体数量上限。',
 'Default response style for new conversations.': '新对话的默认回复风格。',
 'Used for dates, reminders, and scheduled work.': '用于日期、提醒和定时任务。',
 'Show collapsible thinking blocks when provided.': '有思考内容时显示可折叠的思考块。',
 'Show tool calls and expandable details in conversations.': '在对话中显示工具调用及可展开的详情。',
 'Keep completed tool details open by default.': '默认保持已完成的工具详情展开。',
 'Open completed tool details by default.': '默认展开已完成的工具详情。',
 'Choose whether Conduit follows Hermes, always shows, or never shows maintenance updates.': '选择 Conduit 跟随 Hermes、始终显示还是从不显示维护动态。',
 'How Hermes supplies images to a model.': 'Hermes 向模型提供图片的方式。',
 'You can enter any installed model identifier.': '可输入任何已安装模型的标识符。',
 'Leave blank for automatic language detection.': '留空则自动检测语言。',
 'Built-in voices are suggestions; custom voice IDs remain supported.': '内置音色仅作建议；仍支持自定义音色 ID。',
 'Optional speaking style guidance sent to the provider.': '可选的说话风格指引，将发送给提供方。',
 'Speech rate multiplier (0.25–4.0); Hermes clamps this range. Leave blank to remove.': '语速倍率（0.25–4.0），Hermes 会约束该范围。留空则移除。',
 'Open Platform, Step Plan, International, or a custom endpoint.': '开放平台、Step 计划、国际版或自定义端点。',
 'Used only when Endpoint is Custom.': '仅当端点为"自定义"时使用。',
 'Provider speech-rate multiplier.': '提供方语速倍率。',
 'Provider output volume multiplier.': '提供方输出音量倍率。',
 'PCM sample rate requested from Hermes.': '向 Hermes 请求的 PCM 采样率。',
 'Voice ID from your ElevenLabs-compatible endpoint. Leave blank for the provider default.': '与 ElevenLabs 兼容端点的音色 ID。留空则使用提供方默认值。',
 'Enter a valid dashboard URL.': '请输入有效的仪表盘地址。',
 'Enter your dashboard username and password.': '请输入仪表盘的用户名和密码。',
 'Preview is truncated; save the file for its full contents.': '预览已截断，保存文件可查看完整内容。',
 'Sessions and settings follow the active profile. Photos stay only on this device.': '会话与设置跟随当前档案。照片仅保留在此设备上。',
 'Use the arrows to choose the order profiles appear throughout Conduit.': '使用箭头调整各档案在 Conduit 中的显示顺序。',
 'Completed': '已完成', 'Blocked': '已阻塞', 'Reclaimed': '已收回', 'Promoted': '已提级',
 'Scheduled': '已排期', 'Archived': '已归档',
 'Unblocked → \\(status("status") ?? "")': '已解除阻塞 → {0}',
 'Priority set to \\(priority.map(String.init) ?? "?")': '优先级已设为 {0}',
}

def draft_zh(cleaned):
    it = DRAFT.get(cleaned)
    return it['zh'] if it and it.get('zh') and it.get('confidence') in ('exact', 'review') else None

INTERP = re.compile(r'\\\((?:[^()]|\([^()]*\))*\)')
def clean_of(raw):
    return re.sub(r'\s+', ' ', INTERP.sub(' X ', raw).replace('\\n', ' ').replace('\\"', '"').replace("\\'", "'")).strip()

def zh_for(raw):
    return TABLE.get(clean_of(raw)) or draft_zh(clean_of(raw))

# ---- RULE A: wrap bare literals after help:/label:/title:/text: ----
RULE_A = re.compile(r'((?:help|label|title|text)\s*:\s*)("(?:[^"\\\n]|\\.)*")')
changes, per_file = 0, {}
for f in sorted(APP.rglob('*.swift')):
    src = f.read_text(errors='replace')
    out_lines = []
    touched = False
    for line in src.splitlines(keepends=True):
        if line.lstrip().startswith('//'):
            out_lines.append(line); continue
        def repl(m):
            global changes
            lit = m.group(2)
            if re.search(r'String\(localized: $', m.group(1)):  # already wrapped
                return m.group(0)
            raw = lit[1:-1]
            if '\\(' in raw and raw.count('(') != raw.count(')'):
                return m.group(0)  # truncated fragment
            if not zh_for(raw):
                return m.group(0)
            if re.fullmatch(r'[a-z0-9._\-]*', raw):
                return m.group(0)  # technical token
            changes += 1
            per_file[f.name] = per_file.get(f.name, 0) + 1
            return f'{m.group(1)}String(localized: {lit})'
        new = RULE_A.sub(repl, line)
        if new != line: touched = True
        out_lines.append(new)
    if touched:
        f.write_text(''.join(out_lines))
print(f'RULE A: 包裹 {changes} 处 → {len(per_file)} 文件')
for k, v in sorted(per_file.items(), key=lambda x: -x[1]): print(f'  {v:3d}  {k}')

# ---- RULE B: explicit edits (KanbanV2 return-rows, Label tab site, SidebarTab displayName) ----
kv = APP / 'Views/Kanban/KanbanV2Support.swift'
src = kv.read_text()
pairs = [
 ('Row(label: "Completed", detail: nil)', 'Row(label: String(localized: "Completed"), detail: nil)'),
 ('Row(label: "Blocked", detail: string("reason"))', 'Row(label: String(localized: "Blocked"), detail: string("reason"))'),
 ('Row(label: "Unblocked → \\(status("status") ?? "")", detail: nil)',
  'Row(label: String(localized: "Unblocked → \\(status("status") ?? "")"), detail: nil)'),
 ('Row(label: "Reclaimed", detail: string("reason"))', 'Row(label: String(localized: "Reclaimed"), detail: string("reason"))'),
 ('Row(label: "Promoted", detail: nil)', 'Row(label: String(localized: "Promoted"), detail: nil)'),
 ('Row(label: "Scheduled", detail: string("reason"))', 'Row(label: String(localized: "Scheduled"), detail: string("reason"))'),
 ('Row(label: "Archived", detail: nil)', 'Row(label: String(localized: "Archived"), detail: nil)'),
 ('return Row(label: "Priority set to \\(priority.map(String.init) ?? "?")", detail: nil)',
  'return Row(label: String(localized: "Priority set to \\(priority.map(String.init) ?? "?")"), detail: nil)'),
]
n = 0
for old, new in pairs:
    c = src.count(old)
    if c != 1: print(f'⚠️ KanbanV2 {old[:40]!r} 命中 {c}'); continue
    src = src.replace(old, new); n += 1
kv.write_text(src)
print(f'RULE B KanbanV2: {n}/{len(pairs)}')

# SidebarTab displayName + Label site
st = APP / 'Views/SidebarTab.swift'
s = st.read_text()
if 'displayName' not in s:
    s = s.replace('    var id: String { rawValue }', '''    var id: String { rawValue }

    /// 本地化显示名; rawValue 仅用于持久化
    var displayName: String {
        switch self {
        case .sessions: return String(localized: "Sessions")
        case .cron: return String(localized: "Cron")
        case .kanban: return String(localized: "Kanban")
        }
    }''')
    st.write_text(s)
    print('SidebarTab.displayName 已添加')
sv = APP / 'Views/SidebarView.swift'
s = sv.read_text()
if 'Label(tab.displayName' not in s:
    s = s.replace('Label(tab.rawValue, systemImage: tab.icon)', 'Label(tab.displayName, systemImage: tab.icon)')
    sv.write_text(s)
    print('SidebarView Label 已改用 displayName')
# HermesClient 'Sessions' fallback
hc = APP / 'Services/HermesClient.swift'
s = hc.read_text()
old = '?? "Sessions"'
if old in s:
    s = s.replace(old, '?? String(localized: "Sessions")')
    hc.write_text(s)
    print('HermesClient Sessions fallback 已包裹')

# ---- draft 更新: 新增译文字 + 术语修正 ----
added = 0
for en, zh in TABLE.items():
    cur = DRAFT.get(en)
    if not cur or not cur.get('zh'):
        DRAFT[en] = {'zh': zh, 'confidence': 'exact', 'source': 'device-feedback-r1'}
        added += 1
# 术语: Default reasoning → 默认强度
if DRAFT.get('Default reasoning'):
    DRAFT['Default reasoning']['zh'] = '默认强度'
    DRAFT['Default reasoning']['notes'] = '用户指定: reasoning=思考强度, default reasoning=默认强度'
swept = 0
for k, v in DRAFT.items():
    if v.get('zh') and 'reason' in k.lower() and '推理' in v['zh']:
        v['zh'] = v['zh'].replace('推理', '思考'); swept += 1
json.dump(DRAFT, open(DRAFT_P, 'w'), ensure_ascii=False, indent=1)
print(f'draft 新增 {added} 条, 术语推理→思考 {swept} 条')
