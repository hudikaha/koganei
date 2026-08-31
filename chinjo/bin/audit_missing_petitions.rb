#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"

root = File.expand_path("..", __dir__)
data = File.join(root, "koganei_petitions")

def normalize(value)
  value.to_s.tr("０-９", "0-9").gsub(/[[:space:][:punct:]・「」『』（）()]/, "")
       .gsub(/[○×△－議総厚建庁即]/, "")
end

def score(left, right)
  a = normalize(left)
  b = normalize(right)
  return 0.0 if a.length < 4 || b.length < 4
  return 1.0 if a.include?(b) || b.include?(a)

  ap = a.chars.each_cons(2).map(&:join).uniq
  bp = b.chars.each_cons(2).map(&:join).uniq
  (ap & bp).length.to_f / [bp.length, 1].max
end

present = CSV.read(File.join(data, "petitions.csv"), headers: true)
             .map { |row| row["petition_id"] }.to_h { |id| [id, true] }
official = CSV.read(File.join(data, "official_results.csv"), headers: true)
              .group_by { |row| row["petition_id"] }

vision = Dir.glob(File.join(data, "vision_text", "*", "*", "p*.txt")).map do |path|
  text = File.read(path)
  [path, text, text.lines.first(18).join]
end

headers = %w[petition_id official_title candidate_path score candidate_text]
CSV.open(File.join(data, "missing_audit.csv"), "w", write_headers: true, headers: headers) do |csv|
  official.each do |id, records|
    next if present[id]
    reiwa = id[/\A(\d+)陳情/, 1]
    next unless reiwa && reiwa.to_i >= 3
    title = records.map { |row| row["official_title"].to_s }.max_by(&:length).to_s
    candidates = vision.select { |path, _text, head| path.include?("/20#{18 + reiwa.to_i}/") && head.include?("陳情") }
    best = candidates.max_by { |_path, _text, head| score(head, title) }
    next unless best
    value = score(best[2], title)
    csv << [id, title, best[0].sub(data + "/", ""), format("%.3f", value), best[2].gsub(/\s+/, " ").strip]
  end
end
