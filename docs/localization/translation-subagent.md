# 翻译子代理模板（hermes-conduit → zh-Hans）

用途：主代理通过 Agent 工具（`subagent_type: general-purpose`）派发本模板，并行执行批量翻译。
子代理冷启动、无会话上下文，因此提示词必须自包含（路径全部为绝对路径）。

---

## 一、派发参数（主代理每次派发前填写）

| 参数 | 说明 |
|---|---|
| `BATCH_FILE` | 本批待译字符串清单 JSON，格式 `["en1", "en2", …]`（建议每批 100–150 条，从 `conduit-zh-draft.json` 中 `confidence` 为 `none`/`review` 的键切取，批次间不得重叠） |
| `OUTPUT_FILE` | 结果输出绝对路径，如 `/Users/stardo/Project/hermes-conduit/docs/localization/batches/batch-03.json` |
| `SCOPE_NOTE` | 本批字符串的来源语境，如"全部来自 KanbanTaskDetailView 的按钮与空态文案" |

批次切分示例：

```bash
python3 -c "
import json
d = json.load(open('docs/localization/conduit-zh-draft.json'))
todo = [k for k,v in d.items() if v['confidence'] != 'exact']
n = 120
for i in range(0, len(todo), n):
    json.dump(todo[i:i+n], open(f'docs/localization/batches/batch-{i//n+1:02d}.json','w'), ensure_ascii=False, indent=1)
"
```

---

## 二、子代理提示词（将三个参数替换后整体作为 Agent prompt 派发）

```text
你是 hermes-conduit 简体中文本地化的翻译子代理。本次任务：翻译一批 iOS 界面字符串并写出 JSON 结果文件。

## 项目背景（翻译时理解语境用）
hermes-conduit 是一个开源 SwiftUI iOS 客户端（iOS 17+），连接用户自建的 Hermes Agent（AI 代理）仪表盘。功能：流式 Markdown 聊天、工具调用审批、看板式代理编排（Kanban）、语音对话（端上识别 + Whisper）、推送通知、Face ID 锁。文案风格：简洁、专业、面向技术用户；按钮用动词短语，错误消息说明"发生了什么 + 怎么办"。

## 必读文件（先读再用，顺序固定）
1. /Users/stardo/Project/hermes-conduit/docs/localization/术语表.md —— 术语权威依据，译文必须遵守（全读，仅 4KB）
2. /Users/stardo/Project/hermes-conduit/docs/localization/conduit-zh-draft.json —— 既有译稿。**禁止通读（100KB+）**：把批次清单中的英文串作为关键词逐条 grep 本文件查既有译法即可；重叠条目沿用其 exact 译文，review 条目可修订并在 notes 说明理由

## 待翻译批次
清单：BATCH_FILE
语境提示：SCOPE_NOTE

## 硬性规则
1. 术语表优先。术语表已按 **官方 `hermes-agent` → `hermes-desktop` → `hermes-webui`** 优先级定稿，冲突不再人工仲裁，直接照表执行；术语表未覆盖且参考术语库有译法的，可查 /Users/stardo/Project/hermes-conduit/docs/localization/termbase-hermes.json（4,441 条生态术语，**禁止通读（500KB）**，用 python/grep 按英文词条精确查询）。
2. 占位符守恒。源串中的插值标记（独立的词 X，如 "Move X selected X"）在译文中改写为 {0} {1} …（按出现顺序编号，数量必须相等）。已有 {} {0} %@ %d 等占位符原样保留、数量不变。中文无复数变化，不要为复数添加额外变体。
3. 专名不译：Conduit、Hermes、Whisper、Face ID、Touch ID、Siri、Tailscale、Cloudflare、WebSocket、Markdown、OpenAI、Groq、MiMo、YAML、API、URL、ID。模型名与文件名（gpt-4o、whisper-1、distil-whisper-large-v3-en）原样保留。
4. 中文排版：全角标点（，。？！：""''）；中文与英文/数字之间加一个半角空格；省略号用「…」；按钮文案结尾不加句号，完整句（提示/错误说明）结尾用句号。
5. 长度约束：按钮、标签、segment 文案尽量 ≤ 对应英文词数 × 2 个汉字；accessibility/无障碍标签要更精炼。译文明显长于英文时优先压缩措辞，压缩损害语义则保留并在 notes 标注。
6. 语气分工：按钮/动作 = 祈使短语（"归档""批准"）；状态 = 名词短语（"已连接"）；错误 = "X失败：原因"或完整句；确认弹窗标题 = 问句。
7. 不可译条目处理：纯符号、路径片段、扫描噪声（如 "/ X" 这类无独立语义的碎片）→ confidence 填 "none"、zh 填 null、notes 写明"扫描噪声/不可译"。
8. 不确定就标注，禁止编造。术语或语境拿不准 → confidence "review" + notes（≤80 字）写明歧义点；有把握 → "exact"。

## 输出契约（唯一交付物）
用 Write 工具把结果写入：OUTPUT_FILE
格式（UTF-8 JSON，键为英文原文、与批次清单完全一致、不得增删）：
{
  "en string": {"zh": "中文译文或 null", "confidence": "exact|review|none", "notes": "可选，≤80字"}
}

## 写文件前自检（逐条过）
□ 占位符/插值数量与源串一致
□ 键与批次清单一一对应，无遗漏无多余
□ 译文含中文（none 条目除外）、专名未被翻译
□ 全角标点、中英空格、「…」规范
然后运行自检命令并把结果摘要写进你的最终回复：
python3 /Users/stardo/Project/hermes-conduit/docs/localization/check_translations.py OUTPUT_FILE

最终回复只需汇报：完成条数、exact/review/none 分布、自检脚本的 error/warning 数、以及值得主代理仲裁的条目列表。
```

---

## 三、主代理派发与合并 SOP

1. **切批**：用第一节脚本把 `none`/`review` 条目切成 100–150 条/批。
2. **并行派发**：一条消息里并发多个 Agent 调用（`general-purpose`），每个传入替换好参数的第二节提示词。
3. **验收每个产出**：对每个 `OUTPUT_FILE` 运行
   `python3 docs/localization/check_translations.py <OUTPUT_FILE> --base docs/localization/conduit-zh-draft.json`
   有 `[E]` 的批次整批退回重派（把错误清单附进 prompt）；仅 `[W]` 的抽 3–5 条人审。
4. **合并**：
   ```bash
   python3 -c "
   import json, glob
   d = json.load(open('docs/localization/conduit-zh-draft.json'))
   for f in glob.glob('docs/localization/batches/batch-*.json'):
       d.update(json.load(open(f)))
   json.dump(d, open('docs/localization/conduit-zh-draft.json','w'), ensure_ascii=False, indent=1)
   "
   ```
5. **抽查**：合并后随机抽 5% 人工过一遍，重点看 review 档与占位符句。

## 四、经验约定

- **控制子代理读取成本（冒烟实测 2026-09-11）**：termbase-hermes.json（496KB）和 conduit-zh-draft.json（107KB）不要通读——提示词已改为"术语表全读、大文件按需 grep"。若单代理 token 超过 ~40 万，优先检查是否发生了全量大文件通读。
- 批次内按来源文件分组并在 `SCOPE_NOTE` 里写明，同一界面的文案译法更连贯。
- 同一英文串若出现在不同界面含义不同（如 "Archive"），以 conduit-zh-draft.json 已有译法为准保持全局一致；确需一词多译时 notes 里写明界面。
- 子代理只做翻译，不改代码、不动 `Conduit/` 源码；字符串替换进 Swift 是后续独立阶段（String Catalog 改造），由主代理另行派发。
