# skill-hub

把你散落在各处的技能收拢成一份可检索的索引，并让每个 agent 都知道它存在。

解决的问题不是「技能不够」，是 **agent 不知道有什么**——它只看得见自己启动时那几十个，
看不见你另一个目录里的一百多个。

```
.\skill-hub.ps1 index              # 扫描 → index.json
.\skill-hub.ps1 find "PPT 排版"     # 检索
.\skill-hub.ps1 install            # 让 agent 自动看到这个库
```

零依赖，只要 Windows 自带的 PowerShell 5.1+。

---

## 为什么会「找不到」

三个原因，缺一个都会让检索失效：

**1. 目录不在 agent 的搜索范围里。**
Codex 读 `~/.codex/skills`，Qoder 读 `~/.qoder-cn/skills`，WorkBuddy 读自己的。
你把 100 多个技能整理在 `D:\skills`，它们一个都看不见。

**2. 技能太多了，列表反而稀释注意力。**
把 180 个技能全塞进系统提示，模型对单个技能的注意力会下降——
这正是"明明有却不用"的常见原因。

**3. frontmatter 解析不对，描述是空的。**
很多技能写成：

```yaml
description: >
  多行描述的第一行
  第二行
```

只抓 `description:` 那一行会得到 `>`，索引里就是空描述，永远检索不到。

本工具三条都处理了：一个中心库、只装一个路由器技能、认四种块标量写法。

---

## 设计：一个入口，按需检索

```
┌─────────────┐
│  中心技能库  │  180+ 个技能，按分类放
└──────┬──────┘
       │ index
       ▼
   index.json  ──►  find "关键词"  ──►  命中技能的 SKILL.md
       │
       │ install
       ▼
  AGENTS.md 里的一段说明（DSH / Codex 每次会话自动加载）
```

**不给 agent 看全部，只告诉它"有这么个库，先查再动手"。** 检索是动态的，只在需要时花 token。

---

## 命令

| 命令 | 作用 |
|---|---|
| `index` | 扫描技能库，生成 `index.json` |
| `find <关键词...>` | 检索技能与知识库，按相关度排序 |
| `list` | 按分类列出全部 |
| `install` | 把说明写进 `AGENTS.md`（带标记，可重复运行） |
| `sync` | 装一个 `skill-hub` 路由器技能到各客户端 |
| `adopt` | 把只在客户端里的技能并入中心库（只复制，不删原件） |
| `doctor` | 查重复、短描述、坏 frontmatter |

常用参数：`-Root` 技能库位置 · `-Hub` 索引位置 · `-Clients` 要同步的客户端 · `-DryRun` 只演练 · `-Json` 机器可读输出。

---

## 配置

复制 `skill-hub.config.example.json` 为 `skill-hub.config.json`，放在脚本旁边：

```json
{
  "skillsRoot": "D:\\skills",
  "hubDir": "D:\\skill-hub-data",
  "knowledgeRoots": [
    { "id": "项目知识库", "path": "D:\\docs\\kb", "desc": "设计规范与踩坑记录" }
  ],
  "clients": {
    "codex": "~/.codex/skills",
    "claude": "~/.claude/skills"
  },
  "instructionTargets": [
    { "label": "DSH 全局", "path": "$DSH_HOME/AGENTS.md" },
    { "label": "Codex 全局", "path": "~/.codex/AGENTS.md" }
  ]
}
```

不配也能用，默认 `~/.skills` 和 `~/.skill-hub`。

---

## 为什么用 AGENTS.md 而不是插件

`AGENTS.md` 是这一波 agent 工具的通用约定：Claude Code、Codex、DSH 都会读，
DSH 还支持 `AGENTS.override.md` 和逐级向上查找。

`install` 往里面写一段带标记的内容：

```markdown
<!-- SKILL-HUB:BEGIN ... -->
## 本机技能库：先检索，再用
...
<!-- SKILL-HUB:END -->
```

- **幂等**：重复运行只替换标记内的部分
- **不覆盖**：你原有的指令保留
- **可撤**：删掉标记之间的内容即可

比写插件轻得多，而且换个 agent 工具照样有效。

---

## 关于目录结构

```
<skillsRoot>/
├── 01-办公文档/
│   ├── ppt-master/SKILL.md
│   └── doc-typeset/SKILL.md
└── 02-开发/
    └── code-review/SKILL.md
```

分类就是第一层目录名。`_` 开头的目录（如 `_archive`）会被当成存档，不参与检索。

技能自己的结构随意，`index` 只认 `SKILL.md`。

---

## 已知限制

- **关键词匹配，不是语义检索**。中文同义词（"抠图" vs "去背景"）要在查询里都给。
- **知识库只索引标题**，没有做正文全文检索。
- **`sync` 不删东西**。客户端里同名的真实目录会被记为"冲突"并跳过，
  避免误删你改过的版本。
- **只处理 `SKILL.md` 格式**。别的约定（比如纯 README 的技能）需要自己加解析。

---

## 许可

AGPL-3.0-only。
