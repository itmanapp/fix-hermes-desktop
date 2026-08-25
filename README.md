# fix-hermes-desktop

Hermes Desktop（Electron）在 Linux 上**更新後打不開**的修復流程教學。本文件寫給 AI 代理人（agent）閱讀：照著「症狀辨識 → 診斷 → 修復 → 驗證」的順序執行，即可直接修復。

---

## TL;DR（最快路徑）

```bash
# 直接執行本 repo 的自動修復腳本
./fix.sh
```

手動等價指令：

```bash
pkexec chown root:root "$HOME/.hermes/hermes-agent/apps/desktop/release/linux-unpacked/chrome-sandbox"
pkexec chmod 4755       "$HOME/.hermes/hermes-agent/apps/desktop/release/linux-unpacked/chrome-sandbox"
```

---

## 給 AI 的快速判定清單

若使用者說「Hermes 桌面版更新後打不開」，依序確認以下特徵，**全部符合即套用本流程**：

| # | 檢查項 | 符合特徵 |
|---|--------|----------|
| 1 | 啟動方式 | `~/.hermes/hermes-agent/venv/bin/hermes desktop` 或桌面 `.desktop` 捷徑 |
| 2 | 崩潰 log 關鍵字 | `GPU process launch failed: error_code=1002`（重複多次） |
| 3 | 致命錯誤 | `FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:415] GPU process isn't usable. Goodbye.` |
| 4 | 更新日誌線索 | `~/.hermes/logs/desktop.log` 出現 `(its sandbox helper needs root ownership)` |
| 5 | 檔案權限 | `chrome-sandbox` 為 `-rwxr-xr-x <user> <user>`（**應為** `-rwsr-xr-x root root`） |
| 6 | 系統參數 | `cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns` 回傳 `1` |

---

## 根本原因（Root Cause）

1. Hermes 更新腳本會重建 `apps/desktop/release/linux-unpacked/`。
2. 重建後 `chrome-sandbox` 變回普通使用者擁有（如 `hermes:hermes, 755`），**失去 setuid root**。
3. 系統設定 `kernel.apparmor_restrict_unprivileged_userns = 1`（Ubuntu 24.04+ 預設），Chromium 無法改用 unprivileged user namespace sandbox。
4. 兩條沙箱路徑皆不可用 → zygote / GPU / network 等 sandboxed 子行程全部 spawn 失敗（`error_code=1002`）→ 瀏覽器主行程 FATAL 結束。
5. Hermes 自己的更新把關程式碼也明確記載此規則：
   > `chrome-sandbox` PRESENT means **root-owned AND setuid or Electron refuses to boot**
   > （見 `~/.hermes/hermes-agent/scripts/desktop-update/posix.sh` 的 `linux_gate()`）

因此**每次更新都會復發**——這是設計上的必然，不是偶發 bug。

---

## AI 修復流程（Step by Step）

### Step 1 — 重現並確認症狀

```bash
timeout 30 ~/.hermes/hermes-agent/venv/bin/hermes desktop 2>&1 | grep -iE "fatal|gpu process launch"
```

- 看到 `GPU process launch failed: error_code=1002` + `GPU process isn't usable. Goodbye.` → 繼續 Step 2。
- 沒有 → **不是本問題**，停止，改查其他原因（GPU 驅動、Wayland、磁碟空間等）。

### Step 2 — 檢查 chrome-sandbox 權限

```bash
ls -la ~/.hermes/hermes-agent/apps/desktop/release/linux-unpacked/chrome-sandbox
```

- 若為 `-rwxr-xr-x <你的使用者> <你的使用者>`（無 `s`、非 root）→ 確診，繼續 Step 3。
- 若已是 `-rwsr-xr-x root root` → 不是本問題，停止。

輔助判別（可選）：確認 userns 是否被 AppArmor 擋住

```bash
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns   # 1 = 有限制
unshare -Ur true; echo $?                                    # 0 = userns 本身可用
```

### Step 3 — 套用修復

需要一次性 root 權限。GUI 工作階段建議用 `pkexec`（會跳 polkit 密碼視窗；純 terminal 下 sudo 需要 TTY 輸入密碼，AI 的 bash tool 通常無法互動輸入）：

```bash
SB="$HOME/.hermes/hermes-agent/apps/desktop/release/linux-unpacked/chrome-sandbox"
pkexec chown root:root "$SB"
pkexec chmod 4755 "$SB"
ls -la "$SB"   # 必須變成 -rwsr-xr-x root root
```

若在可互動的終端機，等價於：

```bash
sudo chown root:root "$SB" && sudo chmod 4755 "$SB"
```

### Step 4 — 驗證修復

```bash
(timeout 45 ~/.hermes/hermes-agent/venv/bin/hermes desktop >/tmp/hermes-fix-test.log 2>&1 &)
sleep 38
grep -ciE "fatal|isn.t usable" /tmp/hermes-fix-test.log   # 必須為 0
pgrep -cf "linux-unpacked/[H]ermes"                        # 應 >= 3（main + zygotes + utilities）
```

- fatal 數 = 0 且行程存活 → **修復成功**。測試實例會因 timeout 自動結束，請使用者從桌面圖示正常開啟即可。

### Step 5 — 告知使用者復發特性

每次更新 Hermes 後權限都會再次被沖掉。下次更新後若又打不開：重跑 Step 3 兩行指令（或 `./fix.sh`），无需重新诊断。

---

## 常見陷阱（AI Agent 注意事項）

1. **pkill 自殺陷阱**：清理行程時，pattern 不要直接寫死字串，否則會 match 到自己外包的 bash 命令列把自己砍掉。用字元類技巧：
   ```bash
   pkill -f "linux-unpacked/[H]ermes"    # OK
   pkill -f "linux-unpacked/Hermes"      # 危險：可能 match 到自己
   ```
2. **`hermes desktop --no-sandbox` 不可用**：`hermes` CLI parser 不接受未知參數，會直接報 `unrecognized arguments`。
3. **不要用 `ELECTRON_DISABLE_SANDBOX=1` 當正式解法**：它是不安全的逃生口（更新腳本僅把它當 relaunch 豁免條件）。正解永遠是把 `chrome-sandbox` 修回 setuid root。
4. **sudo 在非互動環境會失敗**（`sudo: a terminal is required to read the password`）；GUI session 優先嘗試 `pkexec`。
5. **驗證要等夠久**：崩潰通常發生在啟動後 20–30 秒（network service 重啟連鎖之後），驗證至少觀察 30–40 秒。
6. **error_code=1002 的意義**：子行程 launch 失敗（sandbox 狀態無效），不是 GPU 驅動壞掉。看到 1002 先查 sandbox 權限，不要急著裝顯卡驅動。

---

## 相關路徑速查

| 用途 | 路徑 |
|------|------|
| 沙箱輔助程式（問題檔案） | `~/.hermes/hermes-agent/apps/desktop/release/linux-unpacked/chrome-sandbox` |
| Electron 主程式 | `~/.hermes/hermes-agent/apps/desktop/release/linux-unpacked/Hermes` |
| CLI 啟動器 | `~/.hermes/hermes-agent/venv/bin/hermes`（子命令 `desktop`） |
| 桌面捷徑 | `~/.local/share/applications/hermes.desktop` |
| 桌面端日誌 | `~/.hermes/logs/desktop.log` |
| 更新把關邏輯（root cause 佐證） | `~/.hermes/hermes-agent/scripts/desktop-update/posix.sh` → `linux_gate()` |

## 自動修復腳本

`fix.sh` 會自動執行：診斷（Step 1–2）→ 修復（Step 3，優先 pkexec、退回 sudo）→ 驗證（Step 4），並印出每步結果。

```bash
./fix.sh          # 完整流程
./fix.sh --check  # 只診斷不修改
```
