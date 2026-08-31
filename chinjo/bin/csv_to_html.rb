#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "csv"

ROOT = File.expand_path("..", __dir__)
DATA = File.join(ROOT, "koganei_petitions")
rows = CSV.read(File.join(DATA, "petitions.csv"), headers: true)
e = ->(value) { CGI.escapeHTML(value.to_s) }

table_rows = rows.map do |row|
  relevance = row["building_relevance"]
  petitioner = e.call(row["petitioner"])
  petitioner = petitioner.gsub(/([[:space:]]|　)+/, "\\0<wbr>")
  petitioner = %(<span class="petitioner-nowrap">#{petitioner}</span>) if row["petitioner"] == "住田たつのり"
  date_class = row["date"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? "date date-standard" : "date"
  materials = []
  unless row["image_path"].to_s.empty?
    materials << %(<a href="#{e.call(row["image_path"])}">表紙</a>)
  end
  if !row["split_pdf"].to_s.empty?
    materials << %(<a href="#{e.call(row["split_pdf"])}">原本</a>)
  end
  unless row["decision_source"].to_s.empty?
    materials << %(<a href="#{e.call(row["decision_source"])}">採決資料</a>)
  end
  unless row["newsletter_source"].to_s.empty?
    materials << %(<a href="#{e.call(row["newsletter_source"])}">議会だより</a>)
  end
  <<~HTML
    <tr class="relevance-#{e.call(relevance)} confidence-#{e.call(row["confidence"])}">
      <td class="petition-id">#{e.call(row["petition_id"])}</td>
      <td class="#{date_class}">#{e.call(row["date"])}</td>
      <td class="petitioner">#{petitioner}</td>
      <td class="title">#{e.call(row["title"])}</td>
      <td class="decision-session">#{e.call(row["decision_session"])}</td>
      <td class="decision-date">#{e.call(row["decision_date"])}</td>
      <td class="decision-result">#{e.call(row["decision_result"])}</td>
      <td class="materials">#{materials.empty? ? "—" : materials.join("　")}</td>
      <td class="details confidence" hidden>#{e.call(row["confidence"])}</td>
      <td class="details related" hidden>#{e.call(relevance)}</td>
      <td class="details notes" hidden>#{e.call(row["review_note"])}</td>
    </tr>
  HTML
end.join

html = <<~HTML
  <!doctype html>
  <html lang="ja">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>小金井市議会 陳情書索引</title>
    <style>
      body { font-family: system-ui, sans-serif; margin: 1.5rem; color: #222; }
      .table-scroll { overflow-x: auto; }
      table { border-collapse: collapse; table-layout: fixed; width: 87rem; font-size: 0.9rem; }
      th, td { border: 1px solid #bbb; padding: 0.4rem; vertical-align: top; }
      th { background: #eee; position: sticky; top: 0; }
      th:nth-child(1), td.petition-id { width: 7.5rem; white-space: nowrap; }
      th:nth-child(2), td.date { width: 6rem; max-width: 6rem; overflow-wrap: anywhere; }
      td.date-standard { white-space: nowrap; }
      th:nth-child(3), td.petitioner { width: 6rem; max-width: 7.5rem; overflow-wrap: anywhere; }
      .petitioner-nowrap { white-space: nowrap; }
      th:nth-child(4), td.title { min-width: 24rem; }
      th.decision-session, td.decision-session { width: 9rem; }
      th.decision-date, td.decision-date { width: 6rem; white-space: nowrap; }
      th.decision-result, td.decision-result { width: 4.5rem; white-space: nowrap; }
      th.related, td.related { width: 5rem; white-space: nowrap; }
      th.confidence, td.confidence { width: 3.5rem; white-space: nowrap; }
      th.materials, td.materials { min-width: 10rem; width: 10rem; }
      td.materials a { white-space: nowrap; }
      .relevance-yes { background: #e8f5e9; }
      .relevance-review, .confidence-low { background: #fff3cd; }
      label { margin-right: 1rem; }
    </style>
  </head>
  <body>
    <h1>小金井市議会 陳情書索引</h1>
    <p>OCRによる索引です。「要画像確認」と表示された項目はリンク先画像で確認してください。採決欄が空欄でも、継続審査中または未採決の場合があります。</p>
    <p><a href="building_votes.html">庁舎・福祉会館関連陳情の議員別賛否を見る</a></p>
    <p>
      <label><input type="checkbox" id="related-only" checked> 庁舎・福祉会館関連のみ表示</label>
      <label><input type="checkbox" id="show-details"> 注意などを表示</label>
    </p>
    <div class="table-scroll">
    <table>
      <thead><tr><th>識別番号</th><th>日付</th><th>陳情者</th><th>タイトル</th><th class="decision-session">採決本会議</th><th class="decision-date">採決日</th><th class="decision-result">結果</th><th class="materials">資料</th><th class="details confidence" hidden>確信度</th><th class="details related" hidden>庁舎関連</th><th class="details notes" hidden>注意</th></tr></thead>
      <tbody>#{table_rows}</tbody>
    </table>
    </div>
    <script>
      const relatedOnly = document.querySelector('#related-only');
      const showDetails = document.querySelector('#show-details');
      function filter() {
        document.querySelectorAll('tbody tr').forEach(row => {
          row.hidden = relatedOnly.checked && !row.classList.contains('relevance-yes');
        });
      }
      relatedOnly.addEventListener('change', filter);
      showDetails.addEventListener('change', () => {
        document.querySelectorAll('.details').forEach(cell => { cell.hidden = !showDetails.checked; });
      });
      filter();
    </script>
  </body>
  </html>
HTML

File.write(File.join(DATA, "index.html"), html)
warn "wrote #{rows.length} rows to #{File.join(DATA, 'index.html')}"
