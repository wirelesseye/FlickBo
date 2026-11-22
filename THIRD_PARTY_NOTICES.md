# 第三方授權聲明

FlickBo（滑注音）包含由第三方資料轉換而成的中文詞典。以下授權只適用於相應的第三方材料及其衍生資料，不適用於 FlickBo 自有程式碼。

## Rime Terra Pinyin

- 名稱：Terra Pinyin（地球拼音）
- 作者／維護者：Rime contributors
- 來源：<https://github.com/rime/rime-terra-pinyin>
- 使用版本：commit `8a2c895ad7ee8e2b137d91be77f18f86b04d7fc9`
- 上游 repository 授權：GNU Lesser General Public License v3.0
- 授權全文：隨 App 一併提供的 `LICENSE`，或 <https://www.gnu.org/licenses/lgpl-3.0.html>

使用的原始檔為 `terra_pinyin.dict.yaml`。FlickBo 將其中的拼音讀音轉換為無調注音與聲調，去除重複項目，並重新編排為 SQLite 資料庫，以供離線唯讀查詢。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/` 與 `Vendor/rime-terra-pinyin/` 找到。

## Rime Essay

- 名稱：Rime Essay（Rime 共用預設詞彙表）
- 作者／維護者：Rime contributors
- 來源：<https://github.com/rime/rime-essay>
- 使用版本：commit `e2652ea18609a879eae3e87db5d25b7fbc1a4f93`
- 上游 repository 授權：GNU Lesser General Public License v3.0
- 授權全文：隨 App 一併提供的 `LICENSE`，或 <https://www.gnu.org/licenses/lgpl-3.0.html>

使用的原始檔為 `essay.txt`，內容為共用詞彙與出現頻率。FlickBo 以 Terra Pinyin 的讀音為 Essay 詞條離線標音，將詞頻以 log1p 函數正規化後合併進 SQLite 詞典，作為候選排序的權重；無法由 Terra 標音的詞條會被跳過並記錄於編譯報告。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/` 與 `Vendor/rime-essay/` 找到。

## rime-octagram-data

- 名稱：rime-octagram-data（librime-octagram 語法模型資料，`hant` 分支）
- 作者／維護者：Rime contributors（lotem）
- 來源：<https://github.com/lotem/rime-octagram-data>
- 使用版本：commit `97bf55046aad163c3d1881abae5312040b1bbed9`
- 授權：GNU Lesser General Public License v3.0
- 授權全文：隨 App 一併提供的 `LICENSE`，或 <https://www.gnu.org/licenses/lgpl-3.0.html>

使用的原始檔為 `zh-hant-t-essay-bgw.gram`，內容為以詞為單位的繁體中文 n-gram 統計。FlickBo 將其 darts 雙陣列 trie 解碼為 n-gram 與分數，移除執行期不會查詢的句首（`$` 開頭）條目，改以 UTF-8 重新排序、分區塊前綴壓縮並以 16 位元量化分數，封裝為 `flickbo.gram`。評分方式移植自 BSD 授權的 librime-octagram（<https://github.com/lotem/librime-octagram>）。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/` 與 `Vendor/rime-octagram-data/` 找到。

## rime-emoji

- 名稱：rime-emoji（Rime 繪文字輸入方案資料）
- 作者／維護者：Rime contributors
- 來源：<https://github.com/rime/rime-emoji>
- 使用版本：commit `39d232996de79a95d7bf4b5e8533feed5326b075`
- 授權：GNU Lesser General Public License v3.0
- 授權全文：隨 App 一併提供的 `LICENSE`，或 <https://www.gnu.org/licenses/lgpl-3.0.html>

使用的原始檔為 `opencc/emoji_word.txt`，內容為中文詞與對應繪文字。FlickBo 移除每行開頭重複的詞本身與重複的繪文字，刪去膚色修飾符後多餘的 U+FE0F，驗證每個值都是繪文字，再依 UTF-8 排序輸出為 `flickbo.emoji`，在候選詞之後提供繪文字；未使用 `emoji_category.txt`。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/emoji_data.py` 與 `Vendor/rime-emoji/` 找到。

## Unicode Emoji Data

- 名稱：Unicode emoji data（UTS #51 `emoji-test.txt`）
- 作者／維護者：Unicode, Inc.
- 來源：<https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt>
- 使用版本：Emoji 17.0（Unicode 17.0.0）
- 授權：Unicode License v3
- 授權全文：隨 App 一併提供的 `Unicode-LICENSE.txt`，或 <https://www.unicode.org/license.txt>

使用的原始檔為 `emoji-test.txt`，內容為所有繪文字序列、分組與 CLDR 排序。FlickBo 只保留 fully-qualified 序列，移除膚色變體與 Component 分組，保留分組、繪文字版本與英文短名，依原順序輸出為 `flickbo.emojicatalog`，作為繪文字選單的內容；執行期隱藏系統字型尚未支援的較新版本繪文字。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/emoji_data.py` 與 `Vendor/unicode-emoji/` 找到。

## Unicode CLDR Emoji Annotations

- 名稱：Unicode CLDR 繪文字註解（zh_Hant `annotations` 與 `annotationsDerived`）
- 作者／維護者：Unicode, Inc.
- 來源：<https://github.com/unicode-org/cldr>
- 使用版本：CLDR 49（`release-49`，commit `96e54b273d2da4ec6fbad350ba19ff23fa24a588`）
- 授權：Unicode License v3（CLDR 資料檔）
- 授權全文：隨 App 一併提供的 `Unicode-LICENSE.txt`，或 <https://www.unicode.org/license.txt>

使用的原始檔為 `common/annotations/zh_Hant.xml` 與 `common/annotationsDerived/zh_Hant.xml`，內容為繪文字的繁體中文名稱與搜尋關鍵字。FlickBo 依 Unicode `emoji-test.txt` 的繪文字清單取出每個繪文字的名稱與關鍵字，去除重複後輸出為 `flickbo.emojikeywords`，供繪文字搜尋使用。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/emoji_data.py` 與 `Vendor/cldr-annotations/` 找到。

## rime-prelude

- 名稱：rime-prelude（Rime 基礎設定，`symbols.yaml` 符號表）
- 作者／維護者：Rime contributors
- 來源：<https://github.com/rime/rime-prelude>
- 使用版本：commit `082425ea0684bca36474415d4a0e8db9b016487e`
- 授權：GNU Lesser General Public License v3.0
- 授權全文：隨 App 一併提供的 `LICENSE`（與 rime-emoji 的授權檔內容相同），或 <https://www.gnu.org/licenses/lgpl-3.0.html>

使用的原始檔為 `symbols.yaml`，內容為 Rime 以 `/xx` 輸入的符號清單與全形標點對應。FlickBo 取 `punctuator/full_shape` 的全形標點，以及 `punctuator/symbols` 中的部分清單，依標點、圖形與符號、箭頭、數學與上下標、編號、單位貨幣與日期、注音與外文字母分組，去除同一分類中的重複項目後輸出為 `flickbo.symbols` 的符號部分，作為符號選單的內容；未使用卦名、干支、節氣、帶附加符號的拉丁字母、部首等清單。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/symbol_data.py` 與 `Vendor/rime-prelude/` 找到。

## Mozc Emoticon Palette

- 名稱：Mozc 顏文字選單資料
- 作者／維護者：Google Inc.
- 來源：<https://github.com/google/mozc>
- 使用版本：commit `1527a4cd1217cec4611cd4bc8d46f8c66ea79e6a`
- 授權：BSD 3-Clause License
- 授權全文：隨 App 一併提供的 `Mozc-LICENSE.txt`，或 <https://github.com/google/mozc/blob/master/LICENSE>

使用的原始檔為 `src/data/emoticon/categorized.tsv`，內容為分類好的顏文字，原本供 Google 日本語輸入 Android 版的選單使用。FlickBo 只保留顏文字與分類，捨棄日文讀音，去除同一分類中的重複項目後輸出為 `flickbo.symbols` 的顏文字部分，作為顏文字選單的內容。Mozc 授權檔中 NAIST 與沖繩辭書的條款只適用於 `src/data/dictionary*`，FlickBo 未使用這些檔案。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/symbol_data.py` 與 `Vendor/mozc-kaomoji/` 找到。

## OpenCC

- 名稱：Open Chinese Convert（OpenCC）字典資料
- 作者／維護者：BYVoid 與 OpenCC contributors
- 來源：<https://github.com/BYVoid/OpenCC>
- 使用版本：`ver.1.4.2`（commit `025f371dc76b598d77384fbdab90c937471844d8`）
- 授權：Apache License 2.0
- 授權全文：隨 App 一併提供的 `OpenCC-LICENSE.txt`，或 <https://www.apache.org/licenses/LICENSE-2.0>

使用的原始檔為 `data/dictionary/` 下的 `TWVariants`、`TWVariantsPhrases`、`TWVariantsRevPhrases`、`TWPhrases`、`HKVariants`、`HKVariantsPhrases`、`HKVariantsRevPhrases`、`TSCharacters`、`TSPhrases`、`STCharacters`、`STPhrases` 與 `CJK_Compatibility_Ideographs`。FlickBo 依 OpenCC 的 `reverse.py` 規則產生 `TWVariantsRev` 與 `HKVariantsRev`，只保留每個詞條的預設轉換結果，並將字典與轉換鏈（`t2tw`、`tw2t`、`t2hk`、`hk2t`、`t2s`、`s2t`）重新編排為排序後的二進位檔 `flickbo.opencc`，以 Swift 重新實作 OpenCC 的字典群組最長匹配轉換；`TWPhrases` 則由編譯器併入 SQLite 詞典，作為臺灣字形下臺灣用詞的詞頻，詞典缺少的臺灣用詞以 Terra Pinyin 讀音標音後加入；未使用 OpenCC 的程式碼。轉換工具及來源 manifest 可在 FlickBo repository 的 `Tools/DictionaryCompiler/opencc_data.py` 與 `Vendor/opencc/` 找到。

## CC-CEDICT-derived dictionary data

Terra Pinyin 的詞典 header 說明其參考 CC-CEDICT，並將詞典資料標示為 Creative Commons Attribution-ShareAlike 3.0 Unported（CC BY-SA 3.0）。

- CC-CEDICT：<https://cc-cedict.org/>
- 發布者：MDBG
- 授權：<https://creativecommons.org/licenses/by-sa/3.0/>

FlickBo 所附的 `flickbo.sqlite3` 同時包含 Terra Pinyin 與 Rime Essay 的衍生資料：Terra 詞條與讀音部分依 CC BY-SA 3.0 提供，Essay 詞頻部分依 LGPL-3.0 提供。修改內容包括拼音至注音轉換、離線自動標音、詞頻正規化、資料去重、欄位正規化、完整讀音與聲母（initial）索引建立及 SQLite 封裝。來源、commit、SHA-256、詞典版本及 compiler 版本均保存在 repository 的 `Vendor/` 下各 `SOURCE.json` 與 SQLite `metadata` table。

此資料不附帶任何擔保。CC BY-SA 3.0 的免責與責任限制條款適用。
