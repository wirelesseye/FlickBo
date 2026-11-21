# 詞典與語言模型資料授權

本文件涵蓋 `flickbo.sqlite3`、`flickbo.gram`、`flickbo.opencc`、`flickbo.emoji`、`flickbo.emojicatalog` 與 `flickbo.emojikeywords`。

## flickbo.sqlite3

`flickbo.sqlite3` 同時衍生自兩份上游資料：

### Rime Terra Pinyin

- 上游：<https://github.com/rime/rime-terra-pinyin>
- Commit：`8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9`
- 上游 repository 授權：GNU LGPL v3.0
- 詞典資料授權：Creative Commons Attribution-ShareAlike 3.0 Unported
- CC BY-SA 3.0：<https://creativecommons.org/licenses/by-sa/3.0/>

### Rime Essay

- 上游：<https://github.com/rime/rime-essay>
- Commit：`e2652ea18609a879eae3e87db5d25b7fbc1a4f93`
- 上游 repository 授權：GNU LGPL v3.0
- 授權：<https://www.gnu.org/licenses/lgpl-3.0.html>

Terra 部分提供字音、多音字與明確詞條，依 CC BY-SA 3.0 提供；Essay 部分提供常用詞與詞頻，依 LGPL-3.0 提供。轉換包括拼音至注音轉換、離線自動標音、詞頻正規化、去重、欄位正規化、完整讀音與聲母（initial）索引建立及 SQLite 封裝。## flickbo.gram

- 上游：<https://github.com/lotem/rime-octagram-data>（`hant` 分支，`zh-hant-t-essay-bgw.gram`）
- Commit：`97bf55046aad163c3d1881abae5312040b1bbed9`
- 授權：GNU LGPL v3.0，<https://www.gnu.org/licenses/lgpl-3.0.html>

轉換包括解碼上游 darts trie、移除句首條目、UTF-8 重新排序、分區塊前綴壓縮與分數量化。

完整 attribution 與修改說明見 repository 根目錄的 `THIRD_PARTY_NOTICES.md`。

此資料不附帶任何擔保。

## flickbo.opencc

- 上游：<https://github.com/BYVoid/OpenCC>（`ver.1.4.2`，`data/dictionary/`）
- Commit：`025f371dc76b598d77384fbdab90c937471844d8`
- 授權：Apache License 2.0，<https://www.apache.org/licenses/LICENSE-2.0>（全文見 `Vendor/opencc/OpenCC-LICENSE.txt`）

轉換包括產生反向字典、只保留預設轉換結果、依 UTF-8 排序並與轉換鏈一同封裝為 FZOpenCC 格式。

## flickbo.emoji

- 上游：<https://github.com/rime/rime-emoji>（`opencc/emoji_word.txt`）
- Commit：`39d232996de79a95d7bf4b5e8533feed5326b075`
- 授權：GNU LGPL v3.0，<https://www.gnu.org/licenses/lgpl-3.0.html>

轉換包括移除重複的詞本身與繪文字、刪去膚色修飾符後多餘的 U+FE0F、驗證繪文字並依 UTF-8 排序。

## flickbo.emojicatalog

- 上游：<https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt>（Emoji 17.0）
- 授權：Unicode License v3，<https://www.unicode.org/license.txt>（全文見 `Vendor/unicode-emoji/Unicode-LICENSE.txt`）

轉換包括只保留 fully-qualified 序列、移除膚色變體與 Component 分組，並依原順序輸出分組、繪文字版本、繪文字與英文短名。

## flickbo.emojikeywords

- 上游：<https://github.com/unicode-org/cldr>（CLDR 49，`common/annotations/zh_Hant.xml`、`common/annotationsDerived/zh_Hant.xml`）
- Commit：`96e54b273d2da4ec6fbad350ba19ff23fa24a588`
- 授權：Unicode License v3，<https://www.unicode.org/license.txt>（全文見 `Vendor/cldr-annotations/CLDR-LICENSE.txt`）

轉換包括依 `emoji-test.txt` 的繪文字清單取出名稱與關鍵字、去除重複，並以 tab 分隔輸出。
