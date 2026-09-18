# 小金井市 令和7年度決算

議員向け決算書の埋込テキストから、一般会計・国民健康保険特別会計・介護保険特別会計・後期高齢者医療特別会計の歳入歳出を階層化し、検索可能な円グラフを生成します。下水道事業会計は対象外です。

```sh
make check
make deploy-dry-run
make deploy
```

PDF、生成した `data.json` と `index.html` はGit管理しません。
