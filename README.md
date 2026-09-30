# kaggle-competitions-watch

GitHub Actions 每 10 分钟拉一次 Kaggle 最新比赛列表，有变化就 commit 回本仓库。全程只用 `GITHUB_TOKEN`，不需要 PAT，不需要 Kaggle 登录 cookie。

## 产物

| 文件 | 内容 |
|---|---|
| `COMPETITIONS.md` | 最新一页比赛的表格（标题、主办方、奖金、截止时间、队伍数） |
| `data/latest.json` | 最新一页的原始字段（`ListCompetitions` 返回，去掉了会过期的签名图片 URL 和分类计数） |
| `data/competitions.json` | 累计库：所有出现过的比赛，按 id 存，附 `firstSeen` / `lastChanged` |

## 怎么跑起来的

- `watch.yml`：一个 job 长驻，`loop.sh` 每 `INTERVAL_S`（默认 600 秒）跑一次 `watch.py`，数据有变化才 commit + rebase + push。跑到第 `HANDOFF_MIN`（默认 335）分钟时 `gh workflow run watch.yml` 派生下一代然后退出；`concurrency` 组让下一代排队，交接空档只有 runner 启动那几十秒。
- `tick.yml`：每 5 分钟（GitHub cron 下限）检查有没有存活的 `watch.yml` run，没有就拉起一个。它只做崩溃兜底，正常情况下什么也不做。
- `watch.py`：只用标准库。先匿名 GET `/competitions` 拿 `XSRF-TOKEN` cookie，再带 `x-xsrf-token` POST `competitions.CompetitionService/ListCompetitions`，`SORT_OPTION_NEWEST`。
- 依据：GitHub 文档写明 `GITHUB_TOKEN` 触发的 `workflow_dispatch` 会创建新 run（这是"GITHUB_TOKEN 事件不触发 workflow"规则的例外），所以自我续命不需要 PAT。

## 可调参数（Settings → Secrets and variables → Actions → Variables）

| 变量 | 默认 | 含义 |
|---|---|---|
| `INTERVAL_S` | `600` | 两次拉取的间隔秒数 |
| `HANDOFF_MIN` | `335` | 跑到第几分钟交接给下一代（job 上限 355，硬上限 360） |
| `PAGE_SIZE` | `20` | 每次拉多少条 |
| `LIST_OPTION` | `LIST_OPTION_DEFAULT` | 可改 `LIST_OPTION_ACTIVE` / `LIST_OPTION_COMPLETED` |

## 手动操作

- 整条链都死了：Actions → tick → Run workflow，5 秒后它会拉起 watch。
- 想停：Actions → watch → 取消当前 run，再把 tick 和 watch 两个 workflow 都 Disable。只取消 run 不 disable tick 的话 5 分钟内会复活。
- 每 10 分钟拉一次，watch.py 连续失败 6 次（约 1 小时）会让 run 变红退出，tick 随后重新拉起。
