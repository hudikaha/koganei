#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "open3"

ROOT = File.expand_path("..", __dir__)
DATA = File.join(ROOT, "koganei_petitions")
MANIFEST = File.join(DATA, "references", "manifest.tsv")
OUTPUT = File.join(DATA, "official_results.csv")

def normalize(value)
  value.to_s.tr("０-９", "0-9").gsub(/[[:space:]]+/, " ").strip
end

def compact(value)
  normalize(value).delete(" ")
end

def title_fragment(line)
  value = normalize(line[8, 48])
  return "" if value.empty?
  return "" if value.match?(/[○×△－]{2}|会派略称|付託先略称|審議結果|議決結果|議長裁決|委員会|動議|議員提案/)
  return "" if compact(value).match?(/\d+陳情第\d+号/)

  value
end

manifest = CSV.read(MANIFEST, headers: true, col_sep: "\t")
records = []

manifest.select { |row| row["kind"] == "results" }.each do |row|
  relative = row["local_path"]
  pdf = File.join(DATA, relative)
  basename = File.basename(pdf)
  next unless basename.match?(/seitin|seichin|seigan/i)

  text, status = Open3.capture2("pdftotext", "-layout", pdf, "-")
  next unless status.success?
  lines = text.lines
  header = normalize(lines.first(8).join(" "))
  meeting = header[/令和\s*\d+年?第\s*\d+回(?:定例会|臨時会)/] || row["meeting"]
  reiwa_year = (meeting || header)[/令和\s*(\d+)/, 1]&.to_i
  western_year = reiwa_year ? 2018 + reiwa_year : row["year"].to_i

  lines.each_with_index do |line, index|
    normalized = compact(line)
    match = normalized.match(/(\d+)陳情第(\d+)号/)
    next unless match
    next if normalized.include?("動議")

    petition_id = "#{match[1].to_i}陳情第#{match[2].to_i}号"
    fragments = []
    fragments << title_fragment(lines[index - 1]) if index.positive?
    current_start = line.index(/陳\s*情\s*第/) || 0
    current_tail = line[(current_start + match[0].length)..]
    fragments << title_fragment("        #{current_tail}") if current_tail
    fragments << title_fragment(lines[index + 1]) if index + 1 < lines.length
    title = fragments.reject(&:empty?).join.gsub(/[[:space:]]+/, "")
    title = title.gsub(/[総厚建庁議][○×△－議]+/, "")
                 .gsub(/[○×△－議]{2,}/, "")
                 .gsub(/\A[総厚建庁] |[総厚建庁]\z/, "")
    next if title.empty?

    neighborhood = lines[[index - 1, 0].max..[index + 1, lines.length - 1].min].join(" ")
    # 件名に日付が含まれる場合でも、公式表の右端にある採決日を採る。
    date_match = compact(neighborhood).scan(/(\d{1,2})月(\d{1,2})日/).last
    month = date_match&.[](0)
    day = date_match&.[](1)
    decision_date = month && day ? format("%04d-%02d-%02d", western_year, month.to_i, day.to_i) : ""
    # Official tables often insert spaces between every glyph (for example
    # "採       択" and "承    認").  Search the compacted neighborhood so
    # these are retained as decisive results.
    result = compact(neighborhood)[/(不採択|趣旨採択|採択|承認|審議未了|取り下げ|取下げ|撤回)/, 1].to_s
    result = "取下げ" if result == "取り下げ"

    records << {
      "petition_id" => petition_id,
      "official_title" => title,
      "decision_session" => meeting.to_s,
      "decision_date" => decision_date,
      "decision_result" => result,
      "source_pdf" => relative,
      "source_url" => row["source_url"]
    }
  end
end

headers = %w[petition_id official_title decision_session decision_date decision_result source_pdf source_url]
CSV.open(OUTPUT, "w", write_headers: true, headers: headers) do |csv|
  records.uniq { |record| [record["petition_id"], record["decision_session"], record["decision_date"], record["decision_result"]] }
         .sort_by { |record| [record["petition_id"][/\A\d+/].to_i, record["petition_id"][/第(\d+)号/, 1].to_i, record["decision_date"]] }
         .each { |record| csv << headers.map { |header| record[header] } }
end
warn "wrote #{records.length} official result rows to #{OUTPUT}"
