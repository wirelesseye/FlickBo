# FlickBo（滑注音）開發文件

本文件面向開發者，說明專案結構、架構、建置測試與詞典編譯流程。使用者操作說明請見 [README.md](README.md)，第三方授權細節請見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 專案結構

```text
FlickBoApp/                    SwiftUI 容器 App、設定與測試文字欄
FlickBoKeyboard/               UIKit Keyboard Extension、按鍵與 Flick UI
KeyboardCore/                  鍵盤狀態機、按鍵模型及注音配置
KeyboardCore/ChineseInput/     音節解析、詞庫查詢、詞格與 Top-K 解碼
FlickBoTests/                  狀態機、Flick 映射、中文輸入與效能測試
Tools/DictionaryCompiler/      Rime 詞典與語言模型離線編譯器與 Python 測試
Vendor/rime-terra-pinyin/      鎖定版本的上游詞典、授權與 manifest
Vendor/rime-essay/             鎖定版本的上游預設詞彙、授權與 manifest
Vendor/rime-octagram-data/     鎖定版本的語言模型 manifest 與授權（.gram 本體需另行下載）
Vendor/opencc/                 鎖定版本的 OpenCC 字典、測試案例、授權與 manifest
Vendor/rime-emoji/             鎖定版本的 rime-emoji 詞對繪文字表、授權與 manifest
Vendor/unicode-emoji/          鎖定版本的 Unicode emoji-test.txt、授權與 manifest
Generated/                     編譯產物（SQLite 詞典、FZGram 語言模型、FZOpenCC 字形轉換、繪文字表、繪文字選單與 report）
```

## 架構

### 鍵盤狀態機

`KeyboardEngine` 是純 Swift 狀態機：輸入事件產生一組 `KeyboardUpdate`（文件 effects、候選請求、是否作廢候選），`KeyboardViewController` 只依序把 effects 寫進文件，不自行推斷何時提交。`ZhuyinComposition` 保存已選 chunks 與 pending tokens，`ZhuyinInputToken` 同時供鍵盤狀態與 Parser 使用。這讓組字、刪除、提交與模式切換都能獨立測試。

### 中文輸入核心（`KeyboardCore/ChineseInput/`）

- `SyllableParser` 從詞庫的合法音節清單建立音節格（syllable lattice），支援省略聲調、部分聲調與完整聲調；可同時作為完整音節與聲母前綴的符號（例如 `ㄓ`）會產生完整與聲母縮寫兩條 edge。
- `SQLiteLexiconStore` 以唯讀模式開啟 bundle 內的 SQLite 詞典，只把 400 多個合法無調注音載入記憶體。完整注音查詢走 `base_key`，pattern（exact／initial 混合）查詢由 pattern 推導 `initial_key` 後走索引掃描，掃描量受 scan limit 限制，再逐列套用 exact 條件並在收集滿 result limit 後停止；三種查詢各有具上限的 LRU cache。
- `UserLearningStore` 在 App Group 的獨立 SQLite 資料庫保存選字次數與 2–8 字新詞；`CombinedLexiconStore` 合併內建及使用者詞條，`UserFrequencyScorer` 對提交至少兩次的詞給予上限 2.5 的成本減免。Extension 無 Full Access 時只嘗試唯讀開啟，資料庫不可用時維持內建詞庫輸入；App 可清除資料，鍵盤查詢時以 SQLite `data_version` 更新計數快照。
- `DictionaryMatcher` 沿音節格以統一的 pattern expansion 查詢詞庫：完整 edge 產生 `.exact`、單符號無調 edge 產生 `.initial`，同一位置可同時保留兩種解讀，全部 exact 時仍走快速 `exactMatches`；pattern 與查詢結果都會記憶化，混合查詢受 `patternMatchResultLimit`／`patternMatchScanLimit` 限制。
- `Decoder` 將詞格與 raw 注音音節合併成永遠連通的解碼圖；沒有詞典匹配的片段會以原始注音保留。沒有語言模型時以精確 Top-K DAG 動態規劃輸出穩定排序的候選；有語言模型時改用 librime `Poet` 式的前向 beam search：每個詞以前兩個詞（第一個詞則以游標前文字）為上下文查詢語言模型，每個位置只保留 `beamWidth`（預設 5）個分數最佳且 text／讀音／上下文互異的部分句子，另保留 `frequentWordReserve`（預設 1）個最後一個詞 Essay 詞頻最高的部分句子；raw 注音音節不計語言模型分數並清空上下文。保留名額是因為高頻多音字（「爲」在 Terra 中ㄨㄟˊ、ㄨㄟˋ各 50%）的讀音成本會讓它單獨排在許多罕用單音字之後，在語言模型能依上下文加分（「爲」＋「什麼」）之前就被剔除；多保留一條使 10 token 最壞輸入的 Debug p95 約增加 15%。
- `MappedGramStore` 以 `mmap` 唯讀映射 `flickbo.gram`（FZGram 格式，見 [語言模型編譯](#語言模型編譯)），頁面為可回收的 file-backed clean pages，不計入 Extension 常駐記憶體；查詢先在區塊前綴索引上二分搜尋，再在 16 個 key 的前綴壓縮區塊內循序比對，同時回報是否存在更長的 key 以便提早中止。
- `OctagramGrammar` 逐行移植 librime-octagram 的 `Octagram::Query`（預設 `collocation_max_length` 4、`collocation_min_length` 3、penalty −12／−12／−24／−18）：取上下文最後 3 字的各後綴與詞的前 3 字各前綴組成 key，分數為 `value / 10000` 加上 collocation 或 weak collocation penalty，句尾另查 `詞$`；每個上下文建立一個 scorer，快取以詞首字開頭的查詢結果。Decoder 與 librime 相同，把 `grammarWeight × (−分數)` 加進每個分段的 cost：沒有搭配的詞、沒有上下文的第一個詞與 raw 注音音節都付出 no-collocation penalty（預設 12），有搭配時較低；這個每段固定成本也讓搜尋偏好較少的分段。

`FlickBoTests/Fixtures/ranking-gold.tsv` 是代表性的排序 gold set（上下文、注音、預期首選），`GrammarProductionIntegrationTests.testRankingGoldSet` 會輸出無語言模型與多個 `grammarWeight` 下的首選正確數，並要求預設設定不低於無語言模型。gold set 另含常見多音字單字（ㄨㄟˋ→爲、ㄉㄜ˙→的、ㄒㄧㄥˊ→行…）與詞組。目前 49 句中無語言模型 46 句、語言模型 47 句正確（預設沿用 librime 的 `grammarWeight` 1.0）；仍錯的是「這是我的書」（被「食物」搶先）與「他說得對」（得／的需要語法判斷）。曾試過「以 floor 為基準只給獎勵」的形式，會因每多切一段就多一次獎勵而過度分詞（僅 2 句正確），因此改回 librime 的形式。
- `LexiconChineseInputPipeline` 在初始化時建立並長期持有 store、parser、matcher 與 decoder，把 Top-K 結果轉成精簡的 `InputCandidate`；轉換時依文字合併候選、每組保留分數最低者，raw 注音候選不受合併影響，並在必要時補上 raw 注音候選；若游標前輸入是全範圍的完整單一音節，再從 store 取出該音節所有單字詞條、以同一 scorer 計分後接在最後。
- 詞本身的 cost 由可替換的 `DecoderScorer` 負責，目前 `BaselineDecoderScorer` 使用 Essay 詞頻 `sourceWeight`、Terra 讀音可信度 `pronunciationWeight`、parser cost 與簡易分詞懲罰。詞頻成本為 `frequencyCostScale × (1 − sourceWeight)`（預設 8）：由於 `sourceWeight = log1p(f) / log1p(max)`，這等於相對詞頻負對數的固定倍數（8 時約 0.52 倍），讀音成本則為 `readingCostScale × -log(pronunciationWeight)`（預設 0.35）。原本的 `-log(sourceWeight)` 把對數又取一次對數，「爲」比「未」高約 12 倍的詞頻只換得 0.22 的成本差，抵不過「爲」兩個讀音各 50% 的 0.69 讀音成本，單打ㄨㄟˋ時「爲」排不進前 8 名。讀音權重是估計值（Terra 百分比經 Essay 用量修正，合成詞取各字乘積），全額計分時「長」（ㄓㄤˇ 約 31%）與合成詞「長大」即使詞頻較高仍輸給「漲」「漲大」，因此讀音成本打折。在 gold set 上掃描兩個倍數，詞頻 6–8、讀音 0.3–0.4 的區域在有無語言模型時都最好（無 45／有 47；詞頻 5、讀音全額為 43／45，舊公式 41／42），預設取區域中央。每個詞的分詞懲罰 `wordBoundaryCost` 隨詞頻倍數等比例調為 0.56（原 0.35 對應倍數 5），否則高頻短詞拼接（可以＋看）會比完整詞（可以看）便宜；調整後無語言模型再多對 1 句。使用者選字次數的成本減免（上限 2.5，八次選字約 2.25）沿用原值，因詞頻倍數提高，可追過的詞頻差相對縮小；前後詞的搭配由 `GrammarModel` 另外計分。語言模型檔缺失或損毀時 Pipeline 會記錄錯誤並退回無語言模型的排序，輸入不中斷。
- 語言模型上下文：`ZhuyinComposition.precedingContext` 提供游標前連續的已選文字；若它延伸到組字開頭，`KeyboardViewController` 會在組字開始前讀取 `documentContextBeforeInput`，以 `GrammarContext.tail` 取最後一段連續文字（遇空白、標點或換行即截斷，最多 8 字）接在前面。上下文只存在記憶體中。
- 繪文字候選：`EmojiTable` 讀取 `flickbo.emoji`（見 [繪文字資料編譯](#繪文字資料編譯)）。`LexiconChineseInputPipeline` 在字形轉換之後，對前 `emojiSourceCandidateLimit`（3）個涵蓋全部輸入的非 raw 候選，以 `canonicalText`（查不到時再用顯示文字）查表，把繪文字以 `InputCandidate.emoji(_:for:)` 接在該詞後面，所以首選永遠是詞，同一個繪文字只出現一次。繪文字候選沿用來源詞的讀音與 token 範圍，`isEmoji` 為 true；選取後的 `SelectedChunk.isEmoji` 讓 `learningEntries` 略過它，含繪文字的組字也不會學成新詞，`precedingContext` 遇到繪文字即截斷語言模型上下文。App Group 的 `showsEmojiCandidates`（預設開啟）改變時，`KeyboardViewController` 在下一次 `viewWillAppear` 重建 Pipeline；`flickbo.emoji` 缺失時記錄錯誤並只顯示詞候選。
- 地區字形：詞庫、語言模型與使用者學習資料都維持 OpenCC 標準繁體（傳承字形），只在 Pipeline 邊界轉換，見 [地區字形](#地區字形)。
- Keyboard Extension 的 decoder 上限為 30 個候選（`KeyboardViewController.maximumCandidateCount`）；`KeyboardCore` 的 `DecoderConfiguration.maximumCandidates` 預設為 10。

### 地區字形

`CharacterVariant`（臺灣／香港／大陸／傳承字形，存在 App Group 的 `characterVariant`，預設臺灣）決定 `CandidateTextConverter` 使用的 OpenCC 轉換：輸出用 `t2tw`／`t2hk`／`t2s`，讀取前文用 `tw2t`／`hk2t`／`s2t`。`MappedOpenCCStore` 以 `mmap` 唯讀映射 `flickbo.opencc`，每個轉換步驟是 OpenCC 的 short-circuit 字典群組：在每個位置由群組中第一個有前綴匹配的字典提供最長匹配，沒有匹配的字元原樣保留。

- Decoder 一律在傳承字形下運作；`LexiconChineseInputPipeline` 先把游標前文字轉回傳承字形再交給語言模型，排序完成後才把候選轉為所選字形。轉換後文字相同的候選只保留排序較前者，所以「為」會沿用「爲」的高詞頻。
- 臺灣用詞不在候選階段轉換：兩岸用詞大多讀音不同（軟件 ㄖㄨㄢˇ ㄐㄧㄢˋ、軟體 ㄖㄨㄢˇ ㄊㄧˇ），把「軟體」掛在「軟件」的讀音下並不合理。編譯器改把 OpenCC `TWPhrases` 併入詞庫（見「詞典編譯」），臺灣字形下 `SQLiteLexiconStore(usesTaiwanWeights: true)` 以 `COALESCE(taiwan_source_weight, source_weight)` 取代 Essay 詞頻；pattern 查詢另以部分索引取出該聲母鍵的臺灣權重詞條，與原本依詞頻排序的前 N 筆合併後重新排序，讓掃描上限也依臺灣權重計算。
- `InputCandidate` 與 `SelectedChunk` 同時保存顯示文字 `text` 與傳承字形 `canonicalText`；文件插入顯示文字，`UserLearningStore` 記錄 `canonicalText`，所以切換字形後學習資料仍然有效，也不需要有歧義的反向轉換。
- 後續字詞建議同樣以傳承字形查詢後再轉換。字形設定改變時，`KeyboardViewController` 在下一次 `viewWillAppear` 重建 coordinator 與 Pipeline。
- `flickbo.opencc` 缺失或損毀時記錄錯誤並退回傳承字形，輸入不中斷。

### Extension 整合

`FlickBoKeyboard/ChineseInputCoordinator.swift` 負責非同步協調：每次 pending tokens 改變就增加 revision 並進入 loading，但保留既有候選直到新結果抵達，背景完成後只在 revision 與 token snapshot 都相符時套用結果；詞典缺失或查詢失敗時才發布 raw 注音 fallback。`KeyboardDocumentClient` 與 `DocumentEffectApplier` 隔離 `UITextDocumentProxy`，`CandidateBarView` 以水平 `UICollectionView` 提供固定高度的候選列與展開按鈕，`ExpandedCandidateView` 以垂直 `UICollectionView` 提供展開後的候選列表，兩者都只建立可見範圍的 cell，選項依原寬度自動換行排列。

繪文字選單：點按繪文字鍵時，`KeyboardViewController.showEmojiPanel()` 先以 `KeyboardEngine.commitComposition()` 提交組字中的文字（含未選注音），再以 `EmojiPanelView` 取代按鍵區。`EmojiCatalog` 讀取 `flickbo.emojicatalog`（見 [繪文字資料編譯](#繪文字資料編譯)），並依 `EmojiVersion.supported(byOSVersion:)` 隱藏系統字型尚未支援的版本（iOS 17.4 → 15.1、18.4 → 16.0、26.4 → 17.0，其餘 15.0），避免顯示空白方框。面板上方為繪文字搜尋與符號（&%、:-)）分頁，目前是停用的預留位置；中間的 `UICollectionView` 以 8 欄正方形格線依分類分段，最近使用排在最前；下方為返回鍵（中文模式顯示「中」、數字「123」、英文「ABC」）、分類列與刪除鍵，點分類會捲動到該段，捲動時分類列跟著標示目前分段。最近使用（`RecentEmojiStore`，最多 32 個）存在 Extension 自己的 `UserDefaults.standard`，不需要完整取用。選取繪文字與一般符號鍵相同，經 `KeyboardEngine` 的 `.symbol` 事件插入；面板不顯示候選列。

### 詞典資料

pinned Terra 詞典經過碼表最小化，常見詞如「注音」「你好」原本屬於 Rime 的 preset vocabulary，未包含在 `terra_pinyin.dict.yaml` 中。編譯器改以 pinned Rime Essay 補齊這些常用詞：Terra 提供字音、多音字與明確詞條，Essay 提供常用詞與詞頻；沒有 Terra 明確讀音的 Essay 詞條會以各字的 Terra 單字讀音離線自動標音。

自動標音時，若某字已有正權重讀音，Terra 明確標為 `0%` 的罕見讀音不參與組合（未標權重的讀音仍會保留，例如「於」合成「於是」只會得到 `ㄩˊ ㄕˋ`）；只有當所有讀音皆為 `0%` 或未標權重時，才保留全部讀音作為 fallback。

合併後的 SQLite 以 `(text, base_key, tone_key)` 為唯一鍵，Essay 詞頻經 log1p 正規化為 `source_weight`，因此「注音」「你好」等詞是帶權重的單一詞條，而不是多個無權重單字臨時拼接。schema v4 把詞頻與發音可信度分開：`source_weight` 只存 Essay 詞頻，`pronunciation_weight` 存 Terra 的讀音權重；Terra 單字讀音低於 5% 時以 5% 為下限（例如「於」的 `ㄨˉ` 保留為 0.05，不再被 Essay 詞頻放大），Runtime 成本為詞頻成本（見 `DecoderConfiguration.frequencyCostScale`）加讀音成本（見 `readingCostScale`）。schema v4 也為每個 canonical 讀音寫入 `initial_key`（每個音節第一個注音符號，以 U+001F 分隔）並建立 `pronunciation_initial_key` 索引，供聲母縮寫與完整／縮寫混合的 pattern 查詢等值掃描。無法標音或超過組合上限的詞條會統計在編譯報告中，不會靜默遺失。

## 建置與測試

建置或測試前需先產生 `Generated/flickbo.sqlite3`（見 [詞典編譯](#詞典編譯)），否則 bundle 資源與依賴 production 詞典的測試會失敗。在 Xcode 中選擇 `FlickBo` scheme 後執行 Build 或 Test，或使用命令列（將 `name` 替換成 Xcode 中現有的 iPhone 模擬器）：

```sh
xcodebuild \
  -project FlickBo.xcodeproj \
  -scheme FlickBo \
  -destination 'platform=iOS Simulator,name=<模擬器名稱>' \
  test
```

Swift 測試涵蓋：

- 鍵盤狀態機：ABC 大小寫與 Caps Lock、數字模式輸入與滑動符號配置、ABC 九宮格字母配置、全形／半形轉換、符號變種候選與取代、中文／數字／ABC 模式切換、Flick 方向映射、第一至第四聲與獨立輕聲、聲調保留與連續聲調取代、候選選擇／刪除／Return／空白與模式切換的 effect 順序
- Composition：inline marked text 組合、已選 chunk 撤銷與 source token 還原、音調鍵顯示
- 音節格切分、incomplete／fallback 連通性、完整／聲母縮寫雙重解讀與 eligible edge 判定
- 詞格的多字詞、去重、展開上限，以及 pattern lookup 的記憶化、result／scan limit、cheapest-segmentation 去重與 exact／initial 去重
- Decoder 的 scoring、lattice 驗證、Top-K 限制、去重與 deterministic tie-break
- 語言模型：FZGram 查詢（跨區塊、延伸判定、損毀檔拒絕）、octagram 評分公式（collocation／weak／句尾／無上下文）、beam search 的上下文傳遞與 raw 音節重置，以及 production 語言模型的代表性排序（`ranking-gold.tsv`）
- Pipeline 的 fixture 與 production 候選、同文字候選合併、raw fallback 保留、空輸入與錯誤傳遞
- 完整單一音節輸入會在 Top-K 之後補上該音節所有完全匹配的單字（含省略聲調、超過 Top-K 與去重），多音節輸入不追加
- 聲母與混合縮寫：`ㄅ`、`ㄅㄅ` 的漢字候選與排序，`ㄅㄨㄓㄉ`、`ㄓㄉ`、`ㄎㄧㄎ` 的詞條查詢，以及縮寫候選刪除後還原原始 tokens
- Coordinator 的 stale result 防護、載入期間保留既有候選、invalidate 與初始化失敗 fallback
- Document effect applier 的 UTF-16 selection、替換 marked text 與提交順序
- 候選列與展開列表只建立可見範圍的 cell、第一列可見數計算與展開／收合狀態
- production 詞典的 metadata、entry count、initial key 完整性、來源 manifest 比對、代表性查詢，以及 `EXPLAIN QUERY PLAN` 索引驗證

Python 詞典編譯器另有單元測試與完整 corpus 驗證：

```sh
python3 -m unittest discover \
  -s Tools/DictionaryCompiler/tests \
  -t Tools/DictionaryCompiler/tests
```

## 詞典編譯

上游資料只在更新來源時以 `fetch-terra`／`fetch-essay` 下載，兩者都必須指定完整的 40 字元 commit：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py fetch-terra \
  --commit <terra-commit> --dest Vendor/rime-terra-pinyin

python3 Tools/DictionaryCompiler/compile_dictionary.py fetch-essay \
  --commit <essay-commit> --dest Vendor/rime-essay
```

重建 production 詞典與 report（不需要網路）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build \
  --terra-source Vendor/rime-terra-pinyin/terra_pinyin.dict.yaml \
  --terra-manifest Vendor/rime-terra-pinyin/SOURCE.json \
  --essay-source Vendor/rime-essay/essay.txt \
  --essay-manifest Vendor/rime-essay/SOURCE.json \
  --opencc-source Vendor/opencc \
  --opencc-manifest Vendor/opencc/SOURCE.json \
  --output Generated/flickbo.sqlite3 \
  --report Generated/dictionary-report.json
```

產物 `Generated/flickbo.sqlite3` 不納入版控，clone 後必須先執行此步驟才能建置或測試；`Generated/dictionary-report.json` 雖由 build 產生但仍納入版控，供 production 詞典測試比對。

編譯流程：

- 編譯器先編譯 Terra，建立完整詞與單字讀音索引；Essay 詞條優先使用 Terra 明確詞讀音，否則以單字讀音自動組合，每個詞最多保留 16 組讀音，超過上限會記錄於 report。合成時排除該字已有正權重讀音時 Terra 明確標為 `0%` 的讀音，排除數量記於 report 的 `excludedZeroWeightReadings`；Terra 單字本身的 `0%` 讀音仍會保留在詞典中。
- 讀音延伸（compiler v6）：Terra 常只在短詞上記錄另一種讀音，例如「什麼」有 `she2 me5`（臺灣讀音）與 `shen2 me5`，「爲什麼」「沒什麼」卻只寫 `shen2`，由單字合成的 Essay 詞條也因 `什 she2 0%` 而得不到ㄕㄜˊ。合併後，凡是詞條中嵌入 2–4 字、Terra 列有多種讀音的詞，且該段讀音是其中之一（或整個詞條本身沒有 Terra 明確讀音，屬於單字合成），就補上其他讀音，沿用原詞條的詞頻與讀音權重；嵌入詞由左至右、長者優先、不重疊地挑選。延伸讀音來自 Terra 明確詞條，因此可以超過 16 組的合成上限，但每詞最多 32 組。report 的 `propagatedReadings` 記錄來源詞數、新增讀音數（約 2 萬筆）、達上限的詞數與範例。
- 單字讀音權重（compiler v7）：Terra 的單字百分比是粗略的編輯估計，例如「長」為 `chang2 90%`、`zhang3 10%`，但「成長」「長大」「校長」都讀ㄓㄤˇ。編譯器以 Essay 詞頻乘上 Terra 明確詞條的讀音，累計每個字各讀音在詞中的用量（多讀音詞平分詞頻）；單字本身的 Essay 詞頻無法區分讀音，沿用 Terra 百分比：`用量(r) = (詞中(r) + 單用 × terra(r)) / (詞中 + 單用)`，最後取 `max(terra(r), 用量(r))` 再正規化。詞中讀音不一定是單打時的讀音：輕聲（桌子）、變調（一個）與大陸詞讀音（知識）會把本調壓低，因此用量只能提高讀音、不會壓低 Terra 的權重；只有主讀音為輕聲的字（了、的）才計入輕聲詞例；變調字「一」「不」維持 Terra 百分比。只調整有多種讀音且至少一個 Terra 百分比的字（約 750 字），結果同時用於單字詞條與合成詞的讀音乘積，因此「長」的ㄓㄤˇ由 10% 升至約 31%，「長大」的ㄓㄤˇㄉㄚˋ也隨之提高。report 的 `readingPriors` 記錄調整字數與範例字的前後權重。
- Essay 詞頻以 `log1p(frequency) / log1p(max_frequency)` 正規化為 `source_weight`，與 Terra 詞條以 `(text, base_key, tone_key)` 合併。Terra 的讀音權重（多音字經上述 Essay 用量修正）獨立寫入 `pronunciation_weight`（單字讀音下限 5%，合成詞取各字讀音權重乘積，來源未標權重時為 NULL），Runtime 以兩者相加計分。
- 臺灣用詞（compiler v8、schema v5）：Essay 主要統計大陸用法，「軟體」（0.44）遠低於「軟件」（0.71）。編譯器讀取 manifest 驗證過的 OpenCC `TWPhrases.txt`（約 810 組，值為 OpenCC 標準繁體，與詞庫字形相同），臺灣用詞的 `taiwan_source_weight` 取 `max(自身詞頻, 對應詞詞頻)`，只在臺灣字形使用；已較常用的臺灣用詞維持 NULL。詞庫缺少的臺灣用詞以 Terra 單字讀音合成（同 Essay 合成詞，之後也參與讀音延伸），`source_kind` 為 `opencc-tw`、`source_weight` 為 0，其他字形下排在最後；含 Terra 無法標音字元的詞（「C肝」「BMW集團」）略過。report 的 `taiwanPhrases` 記錄對應數、調整與新增的詞數（約 360 與 295）、略過數與範例。未指定 `--opencc-source` 時（例如測試 fixture）不加入臺灣用詞。
- 每個 canonical 讀音另計算 `initial_key`（schema v4）並建立索引，且驗證其分段數等於 `syllable_count`；完整性統計會寫入 report。
- 無法標音的詞條只會統計在 report；格式錯誤或 hash 不符則會讓 build 失敗。report 也會記錄資料庫大小與編譯時間，資料庫大小有硬上限。

在相同 Python 與 SQLite library 版本下，相同 source bytes 與 compiler 版本會產生 byte-for-byte 相同的 SQLite 檔案與 report；不同 SQLite library 版本只保證 schema、metadata、排序後資料內容與 report 相同，不保證 SQLite 實體 page layout 或檔案 hash 相同。編譯耗時不寫入可重現的 report。output 只加入 `FlickBoKeyboard` 的 bundle resources。

Swift 測試使用的迷你 fixture 由下列命令產生，Python 測試以 logical database snapshot 檢查它是否與 fixture source 同步：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build \
  --terra-source Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.dict.yaml \
  --terra-manifest Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.SOURCE.json \
  --essay-source Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.essay.txt \
  --essay-manifest Tools/DictionaryCompiler/tests/fixtures/zhuyin_tests.essay.SOURCE.json \
  --output FlickBoTests/Fixtures/flickbo-tests.sqlite3 \
  --report /tmp/flickbo-fixture-report.json
```

## 語言模型編譯

語言模型來源為 [rime-octagram-data](https://github.com/lotem/rime-octagram-data) `hant` 分支的 `zh-hant-t-essay-bgw.gram`（約 41 MB，LGPL-3.0）。原始 `.gram` 不納入版控，只有 `Vendor/rime-octagram-data/SOURCE.json` 與 `LICENSE` 納入；clone 後以 manifest 中的 commit 下載（若 commit 與既有 manifest 相同，會驗證 SHA-256 而不改寫 manifest）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py fetch-octagram \
  --commit 97bf55046aad163c3d1881abae5312040b1bbed9 \
  --dest Vendor/rime-octagram-data
```

轉換為 FZGram（不需要網路，約 20 秒、峰值記憶體約 0.5 GB）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build-grammar \
  --source Vendor/rime-octagram-data/zh-hant-t-essay-bgw.gram \
  --manifest Vendor/rime-octagram-data/SOURCE.json \
  --output Generated/flickbo.gram \
  --report Generated/grammar-report.json
```

- `octagram.py` 解碼上游 darts-clone 雙陣列 trie 與 octagram 的 key 編碼，串流輸出 n-gram 與分數（`ln(x) × 10000`）。
- 移除 octagram 不會查詢的句首（`$` 開頭）key，其餘以 UTF-8 bytes 排序，每 16 個 key 為一個前綴壓縮區塊；分數以最小值為基準右移 1 位存成 16 位元（誤差 ≤ 0.0001）。另存每個區塊首 key 前 8 bytes 的索引，讓二分搜尋集中在約 2 MB 的連續記憶體。
- 格式細節見 `octagram.py` 開頭的說明；report 記錄 key 數、長度分布、分數範圍、輸出大小與 SHA-256，輸出大小有 64 MB 硬上限。
- `Generated/flickbo.gram`（約 37 MB）不納入版控，`Generated/grammar-report.json` 納入版控。缺少 `.gram` 時 production 語言模型測試會 skip，鍵盤則退回無語言模型排序。

Swift 測試使用的迷你語言模型 fixture 由下列命令產生（小區塊以涵蓋跨區塊查詢），Python 測試會檢查它是否與 fixture source 同步：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build-grammar \
  --text-source Tools/DictionaryCompiler/tests/fixtures/octagram_tests.txt \
  --block-size 4 \
  --output FlickBoTests/Fixtures/flickbo-tests.gram \
  --report /tmp/flickbo-grammar-fixture-report.json
```

## 字形轉換資料編譯

OpenCC 字典只在更新來源時以 `fetch-opencc` 下載（需指定 tag 解析後的 40 字元 commit，tag 只記錄在 manifest）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py fetch-opencc \
  --commit 025f371dc76b598d77384fbdab90c937471844d8 --tag ver.1.4.2 \
  --dest Vendor/opencc
```

重建 `Generated/flickbo.opencc` 與 Swift golden fixture（不需要網路）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build-opencc \
  --golden FlickBoTests/Fixtures/opencc-cases.tsv
```

- `opencc_data.py` 解析 OpenCC 文字字典（只取每個詞條的第一個值），依 OpenCC `reverse.py`（含 `# @reverse-prefer:` 標註）產生 `TWVariantsRev`／`HKVariantsRev`，並依 OpenCC 1.4.2 的 `data/config/*.json` 定義轉換鏈；格式細節見該檔開頭說明。
- 未實作的 OpenCC 功能：segmentation（這些設定都沒有使用）、`may_output_tofu` 字典（OpenCC 預設關閉）與 `STPhrases_GeneratedFromRegionalPhrases`（只影響讀取前文用的 `s2t`）。
- Python 測試以 OpenCC 上游 `testcases.json` 驗證參考實作（排除 3 個需要 tofu 字典的 `t2s` 案例），並確認納入版控的 `flickbo.opencc` 與 `opencc-cases.tsv` 與來源同步；Swift 測試以同一份 golden 驗證執行期轉換器。
- 產物約 1.8 MB，納入版控，並只加入 `FlickBoKeyboard` 的 bundle resources；授權全文 `Vendor/opencc/OpenCC-LICENSE.txt` 打包進主 App 與 Extension。

## 繪文字資料編譯

rime-emoji 只在更新來源時以 `fetch-emoji` 下載（需指定 40 字元 commit）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py fetch-emoji \
  --commit 39d232996de79a95d7bf4b5e8533feed5326b075 \
  --dest Vendor/rime-emoji
```

重建 `Generated/flickbo.emoji`（不需要網路）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build-emoji
```

- `emoji_data.py` 解析上游 `opencc/emoji_word.txt`（`詞<TAB>詞 繪文字…`），移除開頭的詞本身與重複繪文字，刪去膚色修飾符後多餘的 U+FE0F，並拒絕含文字的值；格式說明見該檔開頭。未使用 `emoji_category.txt`（分類詞對應過多繪文字）。
- 產物約 84 KB、4,669 個詞，納入版控，並只加入 `FlickBoKeyboard` 的 bundle resources；Python 測試確認它與 vendored 來源同步。rime-emoji 的 LGPL 授權與已打包的 Rime 授權全文相同。

繪文字選單的內容來自 Unicode `emoji-test.txt`，只在更新 Emoji 版本時以 `fetch-unicode-emoji` 下載：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py fetch-unicode-emoji \
  --version 17.0.0 \
  --dest Vendor/unicode-emoji
```

重建 `Generated/flickbo.emojicatalog`（不需要網路）：

```sh
python3 Tools/DictionaryCompiler/compile_dictionary.py build-emoji-catalog
```

- `emoji_data.py` 的 `parse_emoji_test` 依 CLDR 順序保留 fully-qualified 序列，移除膚色變體與 Component 分組，輸出 `分組<TAB>繪文字版本<TAB>繪文字<TAB>英文短名`；遇到未知分組、格式錯誤、重複或缺少分組時編譯失敗。
- 產物約 63 KB、1,914 個繪文字，納入版控，並只加入 `FlickBoKeyboard` 的 bundle resources；Python 測試確認它與 vendored 來源同步。授權全文 `Vendor/unicode-emoji/Unicode-LICENSE.txt` 打包進主 App 與 Extension。更新 Emoji 版本時，同時檢查 `EmojiVersion.supported(byOSVersion:)` 的 iOS 對照。

## 效能

`ChineseInputPerformanceTests` 與 `DecoderPerformanceTests` 是防止演算法或 I/O 發生災難性退化的寬鬆保護，不代表產品延遲目標。Release 模擬器的 Decoder p95 上限為 100 ms，完整 parser → matcher → decoder Pipeline p95 上限為 250 ms；測試直接 assert 全部樣本的 p95，並輸出 min、平均與 p95 供比較。語言模型 beam search 以 thread CPU time 量測（避免把等待排程的時間算進去），Release p95 上限 100 ms、Debug 500 ms；在 Release 模擬器上 30 個候選、10 token 的最壞輸入約 50 ms。SQLite open、冷／熱查詢、pattern 查詢、parser 與 matcher 也分別設有 Debug／Release 寬鬆門檻，並涵蓋 2、4、8 個連續聲母的 matcher 測試與「每次 pattern query 最多回傳 result limit」的界線。

加入 Essay、讀音 provenance、聲母索引與讀音延伸後 production 資料庫約 172 MB（仍在 256 MB 上限內）。Extension 啟動仍只把音節 inventory 載入記憶體，詞條查詢維持依 `base_key` 與 `syllable_count`、pattern 查詢依 `initial_key` 與 `syllable_count` 使用索引，掃描量與單次回傳數都有硬上限，pattern 結果與掃描列另有具上限的 LRU cache。

## 資源檔案

`Generated/flickbo.sqlite3` 與 `Generated/flickbo.gram` 是鍵盤執行所需的可重現資源，但不納入版控：`.gitignore` 忽略兩者，歷史中也不存在任何版本。原因是它們可由 pinned `Vendor/` 來源離線重建（見 [詞典編譯](#詞典編譯) 與 [語言模型編譯](#語言模型編譯)），且 SQLite 詞典超過 GitHub 一般 Git blob 的 100 MB 限制；語言模型的上游 `.gram` 同樣不納入版控，只保留 manifest 與授權。clone 或刪除 `Generated/` 後，建置與測試前必須先執行 `build`，並以 `fetch-octagram` 與 `build-grammar` 產生語言模型；`Generated/dictionary-report.json`、`Generated/grammar-report.json` 與 `Generated/LICENSE.md` 仍納入版控。

## 第三方資料

詞典來源以 pinned commit 鎖定，各 `SOURCE.json` 記錄來源、commit、SHA-256 與取得時間，Essay manifest 另記錄 LICENSE SHA-256 與格式版本；`build` 會驗證 source 與 license 的 SHA-256，`fetch-terra`／`fetch-essay` 只能在明確指定 commit 時使用，一般 build 與 App 執行期都不連網。

`Generated/flickbo.sqlite3` 同時包含 Terra Pinyin 與 Rime Essay 的衍生資料，`Generated/flickbo.gram` 衍生自 rime-octagram-data，sidecar 授權位於 `Generated/LICENSE.md`。語言模型的 `fetch-octagram` 同樣只能以明確 commit 下載，`build-grammar` 會驗證 source 與 license 的 SHA-256。完整 attribution、修改說明與授權連結見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；同一份 notices 與上游 LGPL 授權會打包進主 App 及 Keyboard Extension，App 內可從「第三方授權」開啟閱讀。發佈前仍需人工確認最終合規方式。
