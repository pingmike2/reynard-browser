# 上游同步计划（Reynard 0.19.0）

> 目标：把上游 `minh-ton/reynard-browser` 的更新合入 VPS 本地仓库，并评估难度。
> 硬约束：**不能影响现有越狱环境的日常使用**。
> 编写日期：2026-10-27。所有结论基于当前仓库实际状态，不做推测。

---

## 一、结论摘要

| 项 | 结论 |
| --- | --- |
| 总体难度 | **中**。代码合并已完成且低风险，风险集中在引擎重建与 JIT/DDI 真机验证 |
| 代码合并 | 已完成（`e9fd228`），5 处冲突全部解决，无未合并文件 |
| 是否已影响设备 | **没有**。仅改仓库；未 push、未构建、未安装，设备与越狱环境未动 |
| 预计总工时 | 4–6 小时（CI 构建 1.5–3 小时 + 真机验证 1–2 小时 + 回滚余量） |
| 最大风险 | Cryptex DDI 挂载失败导致 JIT 不可用；0.9→0.19 数据迁移不可逆 |

---

## 二、现状基线

| 项 | 值 |
| --- | --- |
| 仓库 | `/root/reynard-browser`（VPS） |
| 当前分支 | `jit-upstream-batch1` |
| 合并提交 | `e9fd228` Merge upstream/main (0.19.0) |
| 上游 | `upstream/main` = `24a99b7`（0.19.0，2026-10-25） |
| 与上游关系 | 0 落后 / 35 领先（含 JIT 分支自有提交） |
| `main` 分支 | 仍停在 `17c9039`（未动） |
| 引擎版本 | `engine/release.txt` = `FIREFOX_158_0_1_RELEASE` |
| 子模块指针 | `engine/firefox` c178247 → **9378fbc**；`support/idevice` 92323d1 → **d32c818** |
| Gecko patches | 454 个 `.patch` |
| 备份分支 | `backup/pre-upstream-merge-20261027`（合并前分支）<br>`backup/main-pre-upstream-merge-20261027`（合并前 main） |
| 构建入口 | `.github/workflows/build-diagnostic.yml`（macOS 26，超时 360 分钟） |

> 上游的 `build.yml` / `build-release.yml` 带 `github.repository_owner == 'minh-ton'` 门禁，
> 在 fork 上不会执行；fork 的产物只能走 `build-diagnostic`。

### 构建链路修复记录（2026-10-28，run `40778595586` 成功出包）

合并后首次真正跑到打包，暴露出三个与上游同步无关、但会挡住出包的问题：

| # | 现象 | 根因 | 处理 |
| --- | --- | --- | --- |
| 1 | `Apply Gecko patches` 失败：`NativeLayerCA.mm:275 patch does not apply` | fork 独有的 `patches/gfx/layers/NativeLayerRootCA-ios-mainthread.patch`（`51c8f5f`）与上游 `fbf7d79` 改了同一段代码，上游 158 已修主线程提交问题 | 删除该 patch（`8e7acc0`）；**不 revert `51c8f5f`**，仅删文件 |
| 2 | `dom/media/fake-cdm` 链接失败：`could not parse bitcode object file ... 'Unknown attribute kind (105)' (Producer: 'LLVM22.1.8' Reader: 'LLVM APPLE_1_2100...')` | Gecko 158 的 `--enable-bootstrap` 工具链升到 LLVM22，Xcode 26 自带 ld64 只认 LLVM21 | 回退 `faa1c19` 在 `toolchain.configure.patch` 里强制的 `kind=ld64` 两段（`a6c8695`），恢复上游「Darwin 优先试 lld」；`LD=ld64.lld` |
| 3 | 构建 6 小时超时（`timeout-minutes: 360`，Hosted runner 硬上限） | 冷启动全量编译 Gecko 158 需 5.4 小时，`actions/cache` 只在 job 成功时写回，失败即白烧 | 接 sccache（`--use-sccache` + `mozilla-actions/sccache-action`，`permissions: actions: write`） |

**结论**：Gecko 158 的 bootstrap clang（LLVM22）与链接器必须同版本。任何让 configure 强制选 Apple `ld64` 的补丁都会重现 issue 2。
`faa1c19` 的两段在 `--enable-linker=ld64` 尚存时是对的，`6a900c4` 移除该 pin 之后即成阻碍 —— 后续若再出类似报错，先查 `patches/build/moz.configure/toolchain.configure.patch` 是否又与上游分叉。

### 真机验证结果（2026-10-29）

- 包：`reynard-diagnostic-a6c86952`（release），主装 `Reynard-Jailbroken.ipa`（109.0 MB）
- 环境：TrollStore + Dopamine（libhooker）
- 结果：**日常使用无异常**。jemalloc 关闭后未出现启动崩溃；JIT 路径正常；底部工具栏 safe area 正常
- 第五节风险表中 #1（DDI）、#2（helper 改名）、#3（libswift 签名）**均未触发**
- 遗留观察项：CALayer 主线程提交依赖上游 `fbf7d79`，本次未做长时滚动压力测试；若后续出现渲染撕裂/崩溃，需重新生成该 patch

---

## 三、零影响原则（必须遵守）

1. **只动仓库，不动设备**。计划中的 P0/P1 全部在 VPS 与 GitHub Actions 完成。
2. **不修改越狱环境**：不改 bootstrap、不装/卸 tweak、不动系统分区与系统库。
3. 唯一涉及系统相关文件的操作是替换 **app bundle 内**的 `libswift_Concurrency.dylib`，不影响其它 App。
4. **不直接覆盖主用机**：先在备用设备或完整备份后验证；旧 IPA 必须保留可随时装回。
5. 保持 bundle id `com.minh-ton.Reynard` 不变，覆盖安装才会保留数据；不要为“并存”而改 id。
6. 不 `force push`、不删除旧 tag/Release、不清理备份分支。
7. 数据迁移不可逆：0.9 → 0.19 有 schema/资源迁移，降级可能丢数据，**装前必须备份容器**。

---

## 四、本次合并内容与冲突处理

- 上游跨度：0.10.0 → 0.19.0，323 个提交，约 720 文件、+118k/−15k 行。
- 5 处冲突的最终处理：

| 文件 | 处理 | 理由 |
| --- | --- | --- |
| `BottomToolbar.swift` | 取上游 | 上游改为贴底布局 + `setAddressBarDockOffset`，fork 的 `bottomInset` 已等价（最终值 0） |
| `BrowserChrome.swift` | 取上游 | 上游 toolbar 贴 `bottomAnchor`、内容锚定 safe area，取代 fork 的 inset 补丁 |
| `AddressBar.swift` | 取上游 | fork 侧为临时 IME 调试日志与 shadowPath，上游已重构；丢弃调试代码 |
| `README.md` | 双方保留 | 上游 Development + fork 的 CI 构建说明 |
| `create-ipa.sh` | 融合 | 采用上游 `--trollstore/--jailbroken` 参数；保留 fork 的 Gecko `ldid` 伪签名与 libswift 下载校验 |

- 同步调整：`build-diagnostic.yml` 改为三次打包（normal / trollstore / jailbroken），仍产出三个 IPA。
- fork 关键能力保留：Gecko 伪签名、三个安装包、CI 自动构建/发布、libswift 兜底。
- fork 已被取代的改动：底部工具栏 inset 系列、IME 临时日志（可不再维护）。

---

## 五、越狱相关风险清单

| # | 风险 | 影响 | 概率 | 缓解措施 |
| --- | --- | --- | --- | --- |
| 1 | Cryptex DDI 挂载失败（`DDIManager`/`JITSupport`） | JIT 不可用，网页卡顿/部分功能异常 | 中高 | 上游已保留 personalized DDI 回退（`b859d35`）；真机看 JIT 状态；失败即回退旧 IPA |
| 2 | JIT helper 名变化：`ptrace_jit` → `ts_ptrace_jit`/`jb_ptrace_jit` | 旧打包脚本产物无 helper，JIT 失败 | 低（已适配） | `JITEnabler.m` 已按新名查找；构建后检查 IPA 内 helper 是否存在且可执行 |
| 3 | libhooker 拒绝 adhoc 签名的 `libswift_Concurrency.dylib` | 越狱包启动崩溃 | 中 | 仅 `--jailbroken` 包替换为 0.10.0 正式签名版本，并在脚本内校验非空；保留旧越狱包 |
| 4 | Gecko 158 在旧 iOS 上的兼容性 | 启动/渲染异常 | 中 | 部署目标仍为 iOS 13.0；TrollStore 官方范围 iOS 14–16.6.1/17.0；以真机验证为准 |
| 5 | 数据 schema 迁移不可逆 | 降级后书签/历史/插件异常 | 中 | 安装前整包备份 app 容器；新版先用导入导出做二次备份 |
| 6 | 454 个 Gecko patch 同步失败 | 构建中断或行为偏差 | 低-中 | CI 的 `apply-patches.sh` 失败即停；本地不手改 patches |
| 7 | `--jailbroken` 依赖外网下载 0.10.0 IPA | 构建失败 | 低 | 脚本已加 `--fail`、重试、非空校验；失败即拒绝出包 |
| 8 | 签名/entitlements 漏项 | 安装失败或 JIT 权限缺失 | 低 | 包内用 `ldid -e` 抽查主程序、helper、ptrace_jit |

---

## 六、分阶段执行计划

### P0 代码合并（已完成）

- [x] 备份分支（合并前分支与 main）
- [x] `git fetch upstream --prune`
- [x] `git merge upstream/main`，解决 5 处冲突
- [x] `sh -n tools/release/create-ipa.sh`、workflow YAML 校验
- [x] 提交 `e9fd228`，工作树干净
- [x] 本计划文档提交（本文件）

### P1 构建（不接触设备，零影响）

1. 推送 `jit-upstream-batch1` 触发 `Build Diagnostic IPA`（路径命中 `browser/**`、`patches/**`）。
2. 等待产物：`Reynard.ipa`、`Reynard-TrollStore.tipa`、`Reynard-Jailbroken.ipa`、构建日志。
3. 静态检查（在 VPS 或本机下载产物后执行）：

```sh
# helper 是否随包
unzip -l dist/Reynard-Jailbroken.ipa | grep -E 'ptrace_jit|libswift_Concurrency'
# 主程序与 helper 的 entitlements
ldid -e Payload/Reynard.app/Reynard | head
# Gecko 框架是否存在并被伪签名
unzip -l dist/Reynard-Jailbroken.ipa | grep GeckoView.framework | head
```

**放行条件**：三个包齐全；越狱包含 `jb_ptrace_jit`；无 `ptrace_jit` 旧名残留；CI 日志无 patch 失败。

### P2 真机验证（备用机优先）

1. 备份 app 容器（TrollStore / Filza，路径 `/var/mobile/Containers/Data/Application/<UUID>`）。
2. 先装 **与设备环境匹配**的包（TrollStore 或越狱包），不要交叉安装。
3. 按第七节验收清单逐项打勾。
4. 任一项失败 → 立即执行第八节回滚，不继续。

### P3 主用机灰度

- 仅在 P2 全绿后，用同样的包覆盖安装；旧版 IPA 保留在同一目录。
- 观察 1–2 天：启动、JIT、后台恢复、下载/上传、音频。

### P4 收尾（需确认后执行）

- 将 `main` 更新到合并结果（当前 main 未动）。
- 决定是否打 tag / 发 Release；决定是否推送。
- 保留备份分支至少一个版本周期。

---

## 七、验收清单（越狱重点）

- [x] 冷启动 3 次无崩溃；二次启动正常
- [x] JIT 状态正确（设置内显示已启用，`about:memory` 可打开）
- [ ] 重启设备后 DDI/JIT 仍可用（Cryptex 路径）
- [x] 上传文件正常（验证 `17c9039` 的 #332 修复未回归）
- [ ] 下载、分享、打印/PDF 正常
- [ ] 音频播放、麦克风/相机权限正常
- [ ] 标签页：切换、总览、静音、播放中标签
- [ ] Reader Mode、自动开启设置
- [ ] 数据导入导出可用；原有书签/历史/插件仍在
- [x] 与常用 tweak 共存（libhooker 注入、无启动崩溃）
- [x] 地址栏、键盘、页面滚动无异常

---

## 八、回滚方案

| 层级 | 操作 | 耗时 |
| --- | --- | --- |
| 应用 | 用保留下来的旧 `Reynard-Jailbroken.ipa` / TrollStore 包覆盖安装 | < 5 分钟 |
| 数据 | 还原安装前备份的 app 容器 | 5–10 分钟 |
| 代码 | `git checkout backup/pre-upstream-merge-20261027`（只切分支，不 force push） | < 1 分钟 |
| 发布 | 不删除旧 Release/tag；如需撤回只删新产物 | < 5 分钟 |

> 注意：若新版已写入迁移后的数据，直接回滚到旧版可能读不了数据，优先还原容器备份。

---

## 九、难度评估

| 环节 | 难度 | 说明 |
| --- | --- | --- |
| 代码合并 | 低 | 已完成；冲突集中在 UI 与打包脚本，均可判定 |
| 引擎重建 | 中 | Gecko 158 + 454 patches；CI 有缓存，指针变更后首次较慢 |
| 打包与签名 | 低 | ldid 流程与三包产出已验证；CI 自动完成 |
| JIT/DDI 运行时 | **中高** | 与设备、iOS 版本、越狱工具强相关，只能真机验证 |
| 数据兼容/回滚 | 中 | 跨 10 个版本，迁移单向 |
| **总体** | **中** | 代码侧不难，真正的门槛是 JIT 真机验证与数据备份 |

---

## 十、待决策

1. 是否现在推送 `jit-upstream-batch1` 触发 CI（会产生一次 1.5–3 小时的构建）。
2. 是否有备用越狱设备；没有则必须先在主用机做完整容器备份。
3. 是否同步更新 `main`。
4. 是否需要发 tag/Release（当前只有 diagnostic 自动发布）。
