#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "open3"
require "pathname"

ROOT = File.expand_path("..", __dir__)
DATA = File.join(ROOT, "koganei_petitions")
CSV_PATH = File.join(DATA, "petitions.csv")

def normalize(value)
  value.to_s.tr("０-９", "0-9").gsub(/[[:space:][:punct:]・「」『』（）()]/, "")
       .gsub(/[○×△－議総厚建庁即]/, "")
end

def decision_sort_key(record)
  meeting = record["decision_session"].to_s
  reiwa = meeting[/令和(\d+)年/, 1].to_i
  number = meeting[/第(\d+)回/, 1].to_i
  [record["decision_date"].to_s.empty? ? 0 : 1, record["decision_date"].to_s, reiwa, number]
end

def newsletter_match(title, newsletter_texts)
  value = normalize(title)
  return nil if value.length < 12
  exact = newsletter_texts.find { |_path, text| text.include?(value) }
  return exact&.first if exact

  window_size = 16
  return nil if value.length < window_size
  windows = value.chars.each_cons(window_size).map(&:join).uniq
  required = [2, (windows.length * 0.35).ceil].max
  scored = newsletter_texts.map { |path, text| [windows.count { |window| text.include?(window) }, path] }
  best_score, best_path = scored.max_by(&:first)
  best_score >= required ? best_path : nil
end

def date_from(text, fallback_year)
  compact = text.to_s.tr("０-９", "0-9").gsub(/[[:space:]]+/, "")
  m = compact.match(/(20\d{2})(?:年|[（(])?.{0,8}?(\d{1,2})月(\d{1,2})日/) ||
      compact.match(/令和(\d+)年?(\d{1,2})月(\d{1,2})日/)
  return "要画像確認" unless m
  year = m[1].to_i >= 2000 ? m[1].to_i : 2018 + m[1].to_i
  month, day = m[2].to_i, m[3].to_i
  return "要画像確認" unless month.between?(1, 12) && day.between?(1, 31)
  year = fallback_year if (year - fallback_year).abs > 1
  format("%04d-%02d-%02d", year, month, day)
end

def petitioner_from(text)
  head = text.lines.first(22).map { |line| line.strip.gsub(/[[:space:]]+/, "") }.reject(&:empty?)
  joined = head.join("\n")
  marked = joined.scan(/(?:共同代表|事務局長|代表者?|氏名)[：:]?([一-龠々ぁ-んァ-ヶ]{2,12})/).flatten.last
  return marked if marked && !marked.match?(/小金井市議会|陳情|住所/)

  rejected = /小金井市議会|議長|陳情|住所|連絡先|令和|西暦|東京都|小金井市|件名|趣旨|様|殿/
  candidates = head.select { |line| line.match?(/\A[一-龠々ぁ-んァ-ヶ・]{2,16}\z/) && !line.match?(rejected) }
  candidates.last || "要画像確認"
end

rows = CSV.read(CSV_PATH, headers: true).map(&:to_h)
headers = CSV.read(CSV_PATH, headers: true).headers
official = CSV.read(File.join(DATA, "official_results.csv"), headers: true).group_by { |row| row["petition_id"] }
reference_manifest = CSV.read(File.join(DATA, "references", "manifest.tsv"), headers: true, col_sep: "\t")
newsletter_meetings = reference_manifest.select { |row| row["kind"] == "newsletters" }.to_h do |row|
  [row["local_path"], row["meeting"].to_s[/令和\d+年第\d+回(?:定例会|臨時会)/].to_s]
end
audit = CSV.read(File.join(DATA, "missing_audit.csv"), headers: true).select { |row| row["score"].to_f >= 0.70 }
path_counts = audit.group_by { |row| row["candidate_path"] }.transform_values(&:length)

headers.concat(%w[record_basis newsletter_source]).uniq!
rows.each { |row| row["record_basis"] ||= "陳情原本" }

audit.each do |candidate|
  next unless path_counts[candidate["candidate_path"]] == 1
  vision_path = File.join(DATA, candidate["candidate_path"])
  next unless File.file?(vision_path)
  image_path = candidate["candidate_path"].sub(%r{\Avision_text/}, "images/").sub(/\.txt\z/, ".png")
  existing = rows.find { |row| row["image_path"] == image_path }
  records = official.fetch(candidate["petition_id"], [])
  decision = records.select { |row| !row["decision_result"].to_s.empty? }.max_by { |row| decision_sort_key(row) }
  text = File.read(vision_path)
  year = candidate["candidate_path"][/vision_text\/(\d{4})\//, 1].to_i
  target = existing || {}
  target["petition_id"] = candidate["petition_id"]
  target["title"] = candidate["official_title"]
  target["date"] = date_from(text, year) if target["date"].to_s.empty?
  target["petitioner"] = petitioner_from(text) if target["petitioner"].to_s.empty? || target["petitioner"].match?(/[●■]|\A[・.印氏名住所]+\z/)
  target["source_pdf"] ||= image_path.sub(%r{\Aimages/(\d{4})/(.+)/p\d+\.png\z}, '\\1/\\2.pdf')
  target["pdf_page"] ||= image_path[/p(\d+)\.png\z/, 1].to_i
  target["image_path"] ||= image_path
  target["ocr_text"] ||= candidate["candidate_path"]
  target["decision_session"] = decision&.[]("decision_session").to_s
  target["decision_date"] = decision&.[]("decision_date").to_s
  target["decision_result"] = decision&.[]("decision_result").to_s
  target["decision_source"] = decision&.[]("source_pdf").to_s
  target["building_relevance"] = normalize(target["title"]).match?(/新庁舎|福祉会館|庁舎建設|庁舎等建設/) ? "yes" : "no"
  target["relevance_note"] = target["building_relevance"] == "yes" ? "庁舎・福祉会館建設関連" : ""
  target["confidence"] = [target["date"], target["petitioner"]].any? { |v| v.to_s.include?("要画像確認") } ? "low" : "high"
  target["review_note"] = target["confidence"] == "low" ? "画像で要確認: 日付・陳情者名" : ""
  target["record_basis"] = existing ? "陳情原本（公式題名で番号補正）" : "陳情原本（本文と公式題名を照合）"
  rows << target unless existing
end

# Add cases whose official title is printed in a council-newsletter PDF but
# whose original petition could not be reconciled above.
newsletter_texts = Dir.glob(File.join(DATA, "references", "newsletters", "**", "*.pdf")).to_h do |path|
  text, = Open3.capture2("pdftotext", "-layout", path, "-", err: File::NULL)
  [path, normalize(text)]
end
present = rows.map { |row| row["petition_id"] }.to_h { |id| [id, true] }
official.each do |id, records|
  next if present[id]
  title_source = records.map { |row| row["official_title"].to_s }.reject(&:empty?).filter_map do |candidate_title|
    next if normalize(candidate_title).length < 12
    source_path = newsletter_texts.find { |_path, text| text.include?(normalize(candidate_title)) }&.first
    source_path ? [candidate_title, source_path] : nil
  end.max_by { |candidate_title, _source_path| normalize(candidate_title).length }
  next unless title_source
  title, source = title_source
  decision = records.select { |row| !row["decision_result"].to_s.empty? }.max_by { |row| decision_sort_key(row) }
  rows << {
    "petition_id" => id, "date" => "議会だよりに記載なし", "petitioner" => "議会だよりに記載なし",
    "title" => title, "building_relevance" => normalize(title).match?(/新庁舎|福祉会館|庁舎建設|庁舎等建設/) ? "yes" : "no",
    "relevance_note" => "", "decision_session" => decision&.[]("decision_session").to_s,
    "decision_date" => decision&.[]("decision_date").to_s, "decision_result" => decision&.[]("decision_result").to_s,
    "confidence" => "low", "review_note" => "陳情原本未確認: 議会だよりから収録",
    "source_pdf" => "", "pdf_page" => "", "image_path" => "", "ocr_text" => "",
    "decision_source" => decision&.[]("source_pdf").to_s, "record_basis" => "議会だよりのみ",
    "newsletter_source" => Pathname(source).relative_path_from(Pathname(DATA)).to_s
  }
end

# Finally retain petitions confirmed by official vote-result material even when
# neither an original petition page nor an exact newsletter-title match exists.
present = rows.map { |row| row["petition_id"] }.to_h { |id| [id, true] }
official.each do |id, records|
  next if present[id]
  m = id.match(/\A(\d+)陳情第(\d+)号\z/)
  next unless m && m[1].to_i.between?(2, 8)
  title = records.map { |row| row["official_title"].to_s }.reject(&:empty?).min_by(&:length).to_s
  next if title.empty?
  decision = records.select { |row| !row["decision_result"].to_s.empty? }.max_by { |row| decision_sort_key(row) }
  rows << {
    "petition_id" => id, "date" => "採決資料に記載なし", "petitioner" => "採決資料に記載なし",
    "title" => title, "building_relevance" => normalize(title).match?(/新庁舎|福祉会館|庁舎建設|庁舎等建設/) ? "yes" : "no",
    "relevance_note" => "", "decision_session" => decision&.[]("decision_session").to_s,
    "decision_date" => decision&.[]("decision_date").to_s, "decision_result" => decision&.[]("decision_result").to_s,
    "confidence" => "low", "review_note" => "陳情原本未確認: 採決資料から収録",
    "source_pdf" => "", "pdf_page" => "", "image_path" => "", "ocr_text" => "",
    "decision_source" => (decision || records.first)&.[]("source_pdf").to_s,
    "record_basis" => "採決資料のみ", "newsletter_source" => ""
  }
end

# Corrections verified directly against the linked original-page images.
manual_names = {
  "3陳情第34号" => "松井豊", "3陳情第47号" => "佐久間昌己",
  "4陳情第28号" => "板倉真也", "4陳情第29号" => "松井豊",
  "4陳情第45号" => "要画像確認（手書き判読困難）", "4陳情第46号" => "要画像確認（手書き判読困難）",
  "4陳情第50号" => "佐久間昌己", "4陳情第79号" => "佐久間昌己",
  "5陳情第2号" => "松井豊", "5陳情第21号" => "新日本婦人の会小金井支部 支部長 小泉久子",
  "5陳情第30号" => "渡邊伸吾", "5陳情第33号" => "渡邊伸吾", "6陳情第10号" => "大会和彦",
  "6陳情第18号" => "渡邊伸吾", "6陳情第25号" => "渡邊伸吾",
  "6陳情第34号" => "佐久間昌己", "6陳情第35号" => "吉池義雄",
  "6陳情第37号" => "渡邊伸吾", "6陳情第38号" => "渡邊伸吾",
  "7陳情第15号" => "大会和彦", "7陳情第42号" => "吉池義雄",
  "7陳情第83号" => "糸井美和", "7陳情第97号" => "佐久間昌己",
  "7陳情第118号" => "東京土建一般労働組合小金井国分寺支部 執行委員長 南哲司",
  "8陳情第7号" => "住田たつのり"
}
title_corrections_path = File.join(ROOT, "corrections", "title_corrections.csv")
manual_titles = CSV.read(title_corrections_path, headers: true).to_h do |correction|
  [correction["petition_id"], correction["title"]]
end
rows.each do |row|
  # The handwritten second digit was dropped by OCR: 3-5 is actually 3-54.
  if row["petition_id"] == "3陳情第5号" && row["image_path"].to_s.end_with?("20210907_petitions_batch01/p0015.png")
    row["petition_id"] = "3陳情第54号"
    row["date"] = "2021-08-19"
    row["petitioner"] = "佐久間昌己"
    canonical = official["3陳情第54号"]&.map { |record| record["official_title"].to_s }&.max_by(&:length)
    row["title"] = canonical unless canonical.to_s.empty?
    row["record_basis"] = "陳情原本（原画像で番号補正）"
  end
  row["petitioner"] = manual_names[row["petition_id"]] if manual_names.key?(row["petition_id"])
  row["title"] = manual_titles[row["petition_id"]] if manual_titles.key?(row["petition_id"])
  if row["petitioner"].to_s.include?("要画像確認")
    row["confidence"] = "low"
    row["review_note"] = "画像で要確認: 陳情者名（手書き判読困難）"
  end
end

# Apply official decision data to every existing petition.  Earlier versions
# only attached it while adding missing records, leaving ordinary source rows
# blank even when the official result PDF had already been downloaded.
rows.each do |row|
  records = official.fetch(row["petition_id"], [])
  decision = records.select { |record| !record["decision_result"].to_s.empty? }
                    .max_by { |record| decision_sort_key(record) }
  next unless decision

  row["decision_session"] = decision["decision_session"]
  row["decision_date"] = decision["decision_date"]
  row["decision_result"] = decision["decision_result"]
  row["decision_source"] = decision["source_pdf"]
end

# Attach the council-newsletter page to every matching petition, including
# petitions that also have an original PDF.
rows.each do |row|
  next unless row["newsletter_source"].to_s.empty?
  source = newsletter_match(row["title"], newsletter_texts)
  row["newsletter_source"] = Pathname(source).relative_path_from(Pathname(DATA)).to_s if source
end

# A council newsletter identifies the session conclusively even when a
# separate vote-result PDF has not yet been associated with the row.
rows.each do |row|
  next unless row["decision_session"].to_s.empty?
  meeting = newsletter_meetings[row["newsletter_source"]]
  row["decision_session"] = meeting unless meeting.to_s.empty?
end

# Some final dispositions are published only in a council newsletter, not in
# the separate vote-result PDFs.  These source-verified overrides also prevent
# a vote on correcting a petition from being mistaken for the petition's final
# disposition.
newsletter_decisions = CSV.read(File.join(ROOT, "corrections", "newsletter_decisions.csv"), headers: true)
                         .to_h { |record| [record["petition_id"], record] }
rows.each do |row|
  decision = newsletter_decisions[row["petition_id"]]
  next unless decision

  row["decision_session"] = decision["decision_session"]
  row["decision_date"] = decision["decision_date"]
  row["decision_result"] = decision["decision_result"]
  row["decision_source"] = ""
  row["newsletter_source"] = decision["newsletter_source"]
end

rows.uniq! { |row| row["petition_id"] }
rows.each do |row|
  %w[date petitioner title].each do |field|
    next unless row[field].to_s.empty?
    row[field] = "要画像確認（原画像から自動判読できず）"
    row["confidence"] = "low"
    row["review_note"] = [row["review_note"], "画像で要確認: #{field}"].reject(&:empty?).join(" / ")
  end
end
rows.sort_by! do |row|
  m = row["petition_id"].to_s.match(/\A(\d+)陳情第(\d+)号\z/)
  m ? [m[1].to_i, m[2].to_i] : [999, 9999]
end
CSV.open(CSV_PATH, "w", write_headers: true, headers: headers) do |csv|
  rows.each { |row| csv << headers.map { |header| row[header] } }
end
warn "reconciled #{rows.length} petitions"
