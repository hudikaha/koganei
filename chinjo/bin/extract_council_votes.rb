#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "cgi"
require "open3"
require "date"

ROOT = File.expand_path("..", __dir__)
PETITIONS_CSV = File.join(ROOT, "koganei_petitions/petitions.csv")
NEWSLETTER_DIR = File.join(ROOT, "koganei_petitions/references/newsletters")
OUTPUT_CSV = File.join(ROOT, "koganei_petitions/building_votes.csv")
OUTPUT_HTML = File.join(ROOT, "koganei_petitions/building_votes.html")

# 議会だよりの縦書き氏名は空白や名の省略があるため、姓を中心に正規化する。
MEMBERS = {
  "森戸" => ["森戸よう子", "日本共産党小金井市議団"],
  "水上" => ["水上洋志", "日本共産党小金井市議団"],
  "たゆ" => ["たゆ久貴", "日本共産党小金井市議団"],
  "片山" => ["片山かおる", "子どもの権利／情報公開"],
  "渡辺" => ["渡辺大三", "子どもの権利／情報公開"],
  "渡辺ふ" => ["渡辺ふき子", "小金井市議会公明党"],
  "高木" => ["高木章成", "子どもの権利を守る会"],
  "古畑" => ["古畑俊男", "子どもの権利を守る会"],
  "村上" => ["村上ようすけ", "れいわ新選組小金井"],
  "藤川" => ["藤川賢治", "小金井市政を見える化する会"],
  "清水" => ["清水学", "自民党・街の仲間たち"],
  "吹春" => ["吹春やすたか", "自由民主党小金井"],
  "坂井" => ["坂井えつ子", "緑・つながる小金井"],
  "田頭" => ["田頭祐子", "小金井市議会公明党"],
  "篠原" => ["篠原ひろし", "小金井市議会公明党"],
  "斎藤" => ["斎藤康夫", "参政党小金井"],
  "水谷" => ["水谷たかこ", "小金井をおもしろくする会"],
  "白井" => ["白井亨", "みらいのこがねい"],
  "板倉" => ["板倉真也", "日本共産党小金井市議団"],
  "沖浦" => ["沖浦あつし", "みらいのこがねい"],
  "岸田" => ["岸田正義", "みらいのこがねい"],
  "鈴木" => ["鈴木成夫", "みらいのこがねい"],
  "村山" => ["村山ひでき", "みらいのこがねい"],
  "宮下" => ["宮下誠", "小金井市議会公明党"],
  "紀" => ["紀由紀子", "小金井市議会公明党"],
  "小林" => ["小林正樹", "小金井市議会公明党"],
  "遠藤" => ["遠藤百合子", "自由民主党小金井"],
  "五十嵐" => ["五十嵐京子", "自由民主党小金井"],
  "湯沢" => ["湯沢綾子", "自由民主党小金井"],
  "河野" => ["河野麻美", "自由民主党小金井"],
  "安田" => ["安田けいこ", "生活者ネットワーク"],
  "天野" => ["天野かな", "みらいのこがねい"],
  "吉良" => ["吉良のりこ", "みらいのこがねい"],
  "太田" => ["太田宏徳", "小金井市議会公明党"],
  "中井" => ["中井れい子", "小金井市議会公明党"],
  "ながとり" => ["ながとり太郎", "小金井をおもしろくする会"],
}.freeze

PRIORITY = %w[森戸 水上 たゆ 片山 渡辺 高木 古畑 村上 藤川].freeze
VOTE_MARKS = %w[○ 〇 × △ 議 欠 － -].freeze
CAUCUS_ABBREVIATIONS = {
  "日本共産党小金井市議団" => "共",
  "子どもの権利／情報公開" => "子",
  "子どもの権利を守る会" => "子",
  "れいわ新選組小金井" => "れ",
  "小金井市政を見える化する会" => "見",
  "小金井をおもしろくする会" => "お",
  "自由民主党小金井" => "自",
  "小金井市議会公明党" => "公",
  "みらいのこがねい" => "み",
  "参政党小金井" => "参",
  "生活者ネットワーク" => "ネ",
  "自民党・街の仲間たち" => "街",
  "緑・つながる小金井" => "緑",
}.freeze
CAUCUS_ORDER = %w[共 子 れ 見 お 自 公 み 参 ネ 街 緑].freeze

Word = Struct.new(:page, :x, :y, :width, :height, :text, keyword_init: true) do
  def cx
    x + width / 2.0
  end
end

def normalize(text)
  text.to_s.unicode_normalize(:nfkc).gsub(/[[:space:][:punct:]・「」（）『』]/, "")
end

def bigrams(text)
  chars = normalize(text).chars
  return chars if chars.length < 2
  chars.each_cons(2).map(&:join).uniq
end

def similarity(a, b)
  aa = bigrams(a)
  bb = bigrams(b)
  return 0.0 if aa.empty? || bb.empty?
  (aa & bb).length.to_f / [aa.length, bb.length].min
end

def read_words(pdf)
  out, status = Open3.capture2("pdftotext", "-tsv", pdf, "-")
  abort "pdftotext failed: #{pdf}" unless status.success?
  out.lines.drop(1).map do |line|
    fields = line.chomp.split("\t", 12)
    next unless fields.length == 12 && fields[0] == "5"
    Word.new(page: fields[1].to_i, x: fields[6].to_f, y: fields[7].to_f,
             width: fields[8].to_f, height: fields[9].to_f, text: fields[11])
  end.compact
end

def surname_for(word)
  compact = normalize(word.text)
  MEMBERS.keys.sort_by { |surname| -surname.length }.find { |surname| compact.start_with?(surname) }
end

def vote_rows(words)
  votes = words.select { |word| VOTE_MARKS.include?(normalize(word.text)) }
  votes.group_by { |word| [word.page, word.y.round] }.values.select { |row| row.length >= 8 }
end

def header_for(words, row)
  page = row.first.page
  y = row.first.y
  min_vote_x = row.map(&:x).min
  header_words = words.select do |word|
    word.page == page && word.y < y && y - word.y < 700 && word.x >= min_vote_x - 10
  end
  candidates = header_words.map do |word|
    surname = surname_for(word)
    next unless surname
    [surname, word]
  end.compact

  # 新しい号では縦書き氏名が一文字ずつ分割される。近いx座標ごとに連結する。
  columns = []
  header_words.sort_by(&:cx).each do |word|
    column = columns.find { |items| (items.first.cx - word.cx).abs < 2.0 }
    column ? column << word : columns << [word]
  end
  columns.each do |items|
    text = items.sort_by(&:y).map(&:text).join
    surname = MEMBERS.keys.sort_by { |key| -key.length }.find { |key| normalize(text).include?(key) }
    next unless surname
    sample = items.first
    candidates << [surname, Word.new(page: page, x: sample.x, y: items.map(&:y).max,
                                     width: sample.width, height: sample.height, text: text)]
  end
  candidates.group_by(&:first).transform_values { |items| items.max_by { |_, word| word.y }.last }
end

def row_title(words, row, all_rows)
  page = row.first.page
  y = row.first.y
  ys = all_rows.select { |other| other.first.page == page }.map { |other| other.first.y }
  min_x = row.map(&:x).min
  words.select do |word|
    next false unless word.page == page && word.x < min_x - 5
    ys.min_by { |row_y| (row_y - word.y).abs } == y
  end.sort_by { |word| [word.y, word.x] }.map(&:text).join
end

def source_label(pdf)
  pdf.delete_prefix("#{NEWSLETTER_DIR}/")
end

def issue_date(pdf)
  basename = File.basename(pdf)
  if (match = basename.match(/(20\d{6})/))
    Date.strptime(match[1], "%Y%m%d")
  elsif basename.include?("gikaidayori273")
    Date.new(2021, 4, 20)
  else
    Date.new(File.basename(File.dirname(pdf)).to_i, 12, 31)
  end
end

def plausible_issue?(petition, pdf)
  return false if petition["decision_date"].to_s.empty?
  decision = Date.parse(petition["decision_date"])
  issue = issue_date(pdf)
  issue >= decision - 30 && issue <= decision + 150
rescue Date::Error
  false
end

petitions = CSV.read(PETITIONS_CSV, headers: true).select do |row|
  row["building_relevance"] == "yes" && !%w[撤回 審議未了].include?(row["decision_result"])
end
extracted = []

Dir.glob(File.join(NEWSLETTER_DIR, "**/*.pdf")).sort.each do |pdf|
  words = read_words(pdf)
  rows = vote_rows(words)
  rows.each do |vote_row|
    title = row_title(words, vote_row, rows)
    eligible = petitions.select { |candidate| plausible_issue?(candidate, pdf) }
    next if eligible.empty?
    petition = eligible.max_by { |candidate| similarity(title, candidate["title"]) }
    score = similarity(title, petition["title"])
    if ENV["DEBUG_VOTES"] == "1" && score >= 0.15
      warn format("%.2f\t%s\t%s\t%s", score, source_label(pdf), petition["petition_id"], title[0, 100])
    end
    next if score < 0.42

    header = header_for(words, vote_row)
    votes = {}
    vote_row.each do |mark|
      nearest = header.min_by { |_, name_word| (name_word.cx - mark.cx).abs }
      next unless nearest && (nearest.last.cx - mark.cx).abs < 7
      votes[nearest.first] = normalize(mark.text).tr("〇", "○")
    end
    next if votes.empty?

    extracted << {
      petition: petition,
      title: title,
      score: score,
      source: source_label(pdf),
      votes: votes,
    }
  end
end

# 同じ陳情を複数箇所で拾った場合は、題名一致度と議員数が最大の行を採る。
extracted = extracted.group_by { |row| row[:petition]["petition_id"] }.values.map do |rows|
  rows.max_by { |row| [row[:score], row[:votes].length] }
end.sort_by do |row|
  id_number = row[:petition]["petition_id"].to_s[/第(\d+)号/, 1].to_i
  [row[:petition]["decision_date"].to_s, id_number]
end

html_rows = extracted.reject { |row| row[:petition]["petition_id"].to_s.match?(/\A[23]陳情/) }
csv_observed = extracted.flat_map { |row| row[:votes].keys }.uniq - %w[板倉]
observed = html_rows.flat_map { |row| row[:votes].keys }.uniq - %w[板倉 白井 湯沢]
member_totals = observed.to_h do |surname|
  [surname, html_rows.count { |row| row[:votes][surname] == "○" }]
end
caucus_max = observed.group_by { |surname| CAUCUS_ABBREVIATIONS.fetch(MEMBERS.fetch(surname)[1]) }
                      .transform_values { |surnames| surnames.map { |surname| member_totals[surname] }.max }
fixed_caucuses = %w[子 共 れ 見 ネ 緑]
tie_order = %w[自 公 み 参 お 街]
caucus_order = fixed_caucuses + (CAUCUS_ORDER - fixed_caucuses).sort_by do |caucus|
  [-caucus_max.fetch(caucus, -1), tie_order.index(caucus) || tie_order.length]
end
member_order = caucus_order.flat_map do |caucus|
  in_caucus = observed.select { |surname| CAUCUS_ABBREVIATIONS.fetch(MEMBERS.fetch(surname)[1]) == caucus }
  (PRIORITY & in_caucus) + (in_caucus - PRIORITY)
end
legend_items = caucus_order.map do |caucus|
  full_names = member_order.map do |surname|
    full_name = MEMBERS.fetch(surname)[1]
    full_name if CAUCUS_ABBREVIATIONS.fetch(full_name) == caucus
  end.compact.uniq
  "#{caucus}＝#{full_names.join('・')}"
end
csv_member_order = member_order + (csv_observed - member_order)
headers = ["陳情番号", "採決日", "件名", "結果", "議会だより"] + csv_member_order.map { |s| MEMBERS.fetch(s).first }
html_headers = ["陳情番号", "採決日", "件名", "結果"] + member_order.map { |s| MEMBERS.fetch(s).first }

CSV.open(OUTPUT_CSV, "w") do |csv|
  csv << headers
  extracted.each do |row|
    petition = row[:petition]
    csv << [petition["petition_id"], petition["decision_date"], petition["title"],
            petition["decision_result"], row[:source], *csv_member_order.map { |s| row[:votes][s] }]
  end
  csv << ["", "", "○合計", "", "", *csv_member_order.map { |s| extracted.count { |row| row[:votes][s] == "○" } }]
end

File.open(OUTPUT_HTML, "w") do |file|
  file.puts <<~HTML
    <!doctype html>
    <html lang="ja"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>庁舎・福祉会館関連陳情 議員別賛否</title>
    <style>
    body{font-family:-apple-system,BlinkMacSystemFont,"Yu Gothic",sans-serif;margin:1rem;color:#222}
    .table-wrap{overflow:auto} table{border-collapse:collapse;font-size:12px;white-space:nowrap}
    th,td{border:1px solid #999;padding:.25rem;text-align:center}
    th.title,td.title{text-align:left;white-space:normal;min-width:24rem}
    th.member{height:7.5rem;min-width:1.55rem;padding:.2rem .1rem;vertical-align:bottom;writing-mode:vertical-rl;text-orientation:mixed}
    th.caucus{font-size:13px}
    tr.totals{font-weight:bold}tr.totals th.label{text-align:right}
    p.legend{font-size:12px;margin:.4rem 0;max-width:100rem;line-height:1.6}
    @page{size:A3 landscape;margin:6mm}
    @media print{
      body{margin:0}h1{font-size:15pt;margin:0 0 2mm}.download{display:none}p.legend{font-size:6.5pt;margin:0 0 2mm;line-height:1.35}
      .table-wrap{overflow:visible}table{width:100%;font-size:6.4pt;table-layout:fixed}
      th,td{padding:.45mm}.petition-id{width:17mm}.date{width:19mm}.title-col{width:103mm}.result{width:12mm}.member-col{width:7mm}
      th.title,td.title{min-width:0}
      th.member{height:22mm;min-width:0;font-size:6.3pt}thead{display:table-header-group}
      tr{break-inside:avoid}
    }
    </style></head><body>
    <h1>庁舎・福祉会館関連陳情 議員別賛否</h1>
    <p class="legend">会派略称：#{legend_items.map { |item| CGI.escapeHTML(item) }.join('　')}</p>
    <p class="download"><a href="building_votes.csv" download>CSVをダウンロード</a></p>
    <div class="table-wrap"><table>
    <colgroup><col class="petition-id"><col class="date"><col class="title-col"><col class="result">#{member_order.map { "<col class=\"member-col\">" }.join}</colgroup>
    <thead>
    <tr><th colspan="4">会派</th>#{member_order.chunk { |s| CAUCUS_ABBREVIATIONS.fetch(MEMBERS.fetch(s)[1]) }.map { |c, items| "<th class=\"caucus\" colspan=\"#{items.length}\">#{c}</th>" }.join}</tr>
    <tr>#{html_headers.map.with_index { |h, i| "<th#{i == 2 ? ' class="title"' : (i >= 4 ? ' class="member"' : '')}>#{CGI.escapeHTML(h)}</th>" }.join}</tr>
    <tr class="totals"><th class="label" colspan="4">○合計</th>#{member_order.map { |s| "<th>#{member_totals[s]}</th>" }.join}</tr>
    </thead><tbody>
  HTML
  html_rows.each do |row|
    petition = row[:petition]
    values = [petition["petition_id"], petition["decision_date"], petition["title"],
              petition["decision_result"], *member_order.map { |s| row[:votes][s] }]
    file.puts "<tr>#{values.map.with_index { |v, i| "<td#{i == 2 ? ' class="title"' : ''}>#{CGI.escapeHTML(v.to_s)}</td>" }.join}</tr>"
  end
  file.puts "</tbody></table></div></body></html>"
end

warn "building votes: #{extracted.length} CSV rows/#{csv_member_order.length} members, #{html_rows.length} HTML rows/#{member_order.length} members"
