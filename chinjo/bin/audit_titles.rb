#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"

root = File.expand_path("..", __dir__)
data = File.join(root, "koganei_petitions")
output = File.join(data, "title_audit.csv")
check = ARGV.delete("--check")

patterns = {
  "陳情書の誤読" => /陳情[費晝責]/,
  "語句の誤読" => /コストラ|新社会館|撤回長|撤即|解即|求庁/,
  "連番の誤読" => /その[／\/]/,
  "伏字状のOCR" => /[〇○●]{2,}/,
  "先頭のOCRノイズ" => /\A[.・●-]{2,}/
}

rows = CSV.read(File.join(data, "petitions.csv"), headers: true)
suspects = rows.filter_map do |row|
  next unless row["building_relevance"] == "yes"
  reasons = patterns.filter_map { |name, pattern| name if row["title"].to_s.match?(pattern) }
  next if reasons.empty?
  [row["petition_id"], row["title"], row["image_path"], reasons.join(" / ")]
end

CSV.open(output, "w", write_headers: true,
         headers: %w[petition_id title image_path reasons]) do |csv|
  suspects.each { |row| csv << row }
end

warn "title audit: #{suspects.length} suspect related titles; wrote #{output}"
exit 1 if check && !suspects.empty?
