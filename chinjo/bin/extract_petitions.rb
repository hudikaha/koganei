#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "pathname"

ROOT = File.expand_path("..", __dir__)
DATA = File.join(ROOT, "koganei_petitions")
OUTPUT = File.join(DATA, "petitions.csv")

def compact(text)
  text.to_s.tr("０-９", "0-9").gsub(/[[:space:]]+/, "")
end

def clean_line(line)
  line.to_s.strip.gsub(/[[:space:]]+/, " ")
end

def vision_cover?(text)
  value = compact(text.lines.first(18).join)
  value.match?(/文.{0,3}表/) && value.match?(/\d+陳情第\d+号/)
end

def extract_id(text)
  match = compact(text).match(/(\d+)陳情第(\d+)号/)
  match ? "#{match[1].to_i}陳情第#{match[2].to_i}号" : ""
end

def extract_title(text)
  lines = text.lines.map { |line| clean_line(line) }.reject(&:empty?)
  id_index = lines.index { |line| compact(line).match?(/\d+陳情第\d+号/) }
  return "" unless id_index

  title_lines = []
  lines[(id_index + 1)..].to_a.each do |line|
    normalized = compact(line)
    break if normalized.match?(/趣旨|別紙のとおり/)
    next if normalized.match?(/^[・。.、]$/)
    title_lines << normalized
  end
  title_lines.join
end

def extract_date(text, fallback_year)
  value = compact(text)
  before_address = value.split(/住所|陳情代表者/, 2).first
  matches = before_address.scan(/令和(\d+|[：:※])年?(\d{1,2})月(\d{1,2})日/)
  match = matches.find { |_year, month, day| month.to_i.between?(1, 12) && day.to_i.between?(1, 31) }
  if match
    reiwa, month, day = match
    year = reiwa.match?(/\A\d+\z/) ? 2018 + reiwa.to_i : fallback_year
    return format("%04d-%02d-%02d", year, month.to_i, day.to_i)
  end

  western = before_address.match(/(20\d{2})年.*?(\d{1,2})月(\d{1,2})日/)
  return format("%04d-%02d-%02d", western[1].to_i, western[2].to_i, western[3].to_i) if western

  # The handwritten Reiwa year is often missed while the printed Western-year
  # parenthesis survives elsewhere on the same line block.
  month_day = before_address.match(/(\d{1,2})月(\d{1,2})日/)
  western_year = before_address.match(/20\d{2}/)
  year = western_year ? western_year[0].to_i : fallback_year
  if month_day && month_day[1].to_i.between?(1, 12) && month_day[2].to_i.between?(1, 31)
    return format("%04d-%02d-%02d", year, month_day[1].to_i, month_day[2].to_i)
  end

  ""
end

def extract_petitioner(text)
  lines = text.lines.map { |line| clean_line(line) }.reject(&:empty?)
  limit = lines.index { |line| compact(line).include?("法人の場合") } || lines.length
  before_legal = lines[0...limit]
  marker = before_legal.index { |line| compact(line).match?(/ほか|外\d*人/) } || before_legal.length
  candidates = before_legal[0...marker].reverse.map { |line| compact(line) }
  candidates.find do |value|
    next false if value.length < 2 || value.length > 80
    next false if value.match?(/^(印|氏|名|人|住|所|陳|情|代表|者|連絡先)$/)
    next false if value.match?(/陳情第|陳情書|趣旨|別紙|令和|西暦|20\d{2}年/)
    next false if value.match?(/^(東京都|小金井市|西東京市|武蔵野市|府中市|国分寺市).*(町|市|区)/)
    next false if value.match?(/^[\d()（）・.：:]+$/)
    true
  end.to_s.sub(/印\z/, "")
end

def relevance(title, petitioner)
  pattern = /新庁舎|福祉会館|新福祉会館|庁舎建設|庁舎等建設|庁舎問題|庁舎床面積|暫定庁舎|第二庁舎.*耐震|本庁舎.*耐震|現設計|見直し案/
  return ["yes", "庁舎・福祉会館建設関連"] if compact(title).match?(pattern)

  ["no", ""]
end

def title_similarity(left, right)
  a = compact(left).gsub(/[[:punct:]]/, "")
  b = compact(right).gsub(/[[:punct:]]/, "")
  return 0.0 if a.empty? || b.empty?
  return 1.0 if a == b

  a_pairs = a.chars.each_cons(2).map(&:join).uniq
  b_pairs = b.chars.each_cons(2).map(&:join).uniq
  (a_pairs & b_pairs).length.to_f / (a_pairs | b_pairs).length
end

official_path = File.join(DATA, "official_results.csv")
official = File.file?(official_path) ? CSV.read(official_path, headers: true).group_by { |row| row["petition_id"] } : {}
rows = []

Dir.glob(File.join(DATA, "vision_text", "*", "*", "p*.txt")).sort.each do |vision_path|
  vision_text = File.read(vision_path, encoding: Encoding::UTF_8)
  next unless vision_cover?(vision_text)
  next if vision_path.include?("_correction_")

  relative = Pathname(vision_path).relative_path_from(Pathname(File.join(DATA, "vision_text"))).to_s
  year, stem, page_file = relative.split("/")
  page = Integer(page_file[/\d+/], 10)
  petition_id = extract_id(vision_text)
  title = extract_title(vision_text)
  date = extract_date(vision_text, year.to_i)
  date = date.sub(/\A\d{4}/, year) if !date.empty? && (date[0, 4].to_i - year.to_i).abs > 1
  petitioner = extract_petitioner(vision_text)
  petitioner = "住田たつのり" if petitioner.include?("住田")
  petitioner = "高木章成" if petitioner.include?("高木")
  petitioner = "渡邊伸吾" if %w[5陳情第28号 5陳情第32号 6陳情第26号 6陳情第50号].include?(petition_id)
  petitioner = "住田たつのり" if petition_id == "6陳情第63号"
  if petition_id.match?(/\A6陳情第(?:5[4-9]|6\d)号\z/) ||
     petition_id.match?(/\A7陳情第12[2-5]号\z/) || petition_id == "8陳情第5号"
    petitioner = "住田たつのり"
  end
  petitioner = "高木章成" if petition_id.match?(/\A7陳情第12[6-9]号\z/)

  official_matches = official.fetch(petition_id, [])
  best_title = official_matches.max_by { |record| title_similarity(title, record["official_title"]) }
  if best_title && title_similarity(title, best_title["official_title"]) >= 0.55
    candidate = best_title["official_title"].gsub(/[総厚建庁議][○×△－議]+/, "").gsub(/[○×△－議]{2,}/, "")
    title = candidate unless candidate.empty?
  elsif title.empty?
    candidates = official_matches.map { |record| record["official_title"].to_s }
                                 .reject(&:empty?).uniq
    title = candidates.max_by(&:length).to_s if candidates.length == 1
  end
  decision = official_matches.select { |record| !record["decision_result"].to_s.empty? }
                             .max_by { |record| record["decision_date"].to_s }

  related, related_note = relevance(title, petitioner)
  missing = []
  missing << "識別番号" if petition_id.empty?
  missing << "日付" if date.empty?
  missing << "陳情者名" if petitioner.empty?
  missing << "タイトル" if title.empty?
  suspicious_ocr = title.match?(/陳情[費晝責]|[.。・]{3,}|〇{2,}|即\z/) ||
                   petitioner.match?(/\A[・.●印名]+\z/)
  missing << "OCR読取り" if suspicious_ocr

  rows << {
    "petition_id" => petition_id,
    "date" => date,
    "petitioner" => petitioner,
    "title" => title,
    "building_relevance" => related,
    "relevance_note" => related_note,
    "decision_session" => decision&.[]("decision_session").to_s,
    "decision_date" => decision&.[]("decision_date").to_s,
    "decision_result" => decision&.[]("decision_result").to_s,
    "confidence" => missing.empty? ? "high" : "low",
    "review_note" => missing.empty? ? "" : "画像で要確認: #{missing.join('・')}",
    "source_pdf" => "#{year}/#{stem}.pdf",
    "pdf_page" => page,
    "image_path" => "images/#{year}/#{stem}/#{page_file.sub(/\.txt\z/, ".png")}",
    "ocr_text" => "vision_text/#{relative}",
    "decision_source" => decision&.[]("source_pdf").to_s
  }
end

rows.uniq! { |row| [row["petition_id"], row["source_pdf"], row["pdf_page"]] }
rows.sort_by! do |row|
  match = row["petition_id"].match(/\A(\d+)陳情第(\d+)号\z/)
  match ? [match[1].to_i, match[2].to_i, row["source_pdf"], row["pdf_page"]] : [999, 9999, row["source_pdf"], row["pdf_page"]]
end

headers = %w[petition_id date petitioner title building_relevance relevance_note decision_session decision_date decision_result confidence review_note source_pdf pdf_page image_path ocr_text decision_source]
CSV.open(OUTPUT, "w", write_headers: true, headers: headers) do |csv|
  rows.each { |row| csv << headers.map { |header| row[header] } }
end
warn "wrote #{rows.length} petitions to #{OUTPUT}"
