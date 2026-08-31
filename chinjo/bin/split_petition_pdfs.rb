#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "open3"

ROOT = File.expand_path("..", __dir__)
DATA = File.join(ROOT, "koganei_petitions")
CSV_PATH = File.join(DATA, "petitions.csv")
OUTPUT_DIR = File.join(DATA, "split")

rows = CSV.read(CSV_PATH, headers: true).map(&:to_h)
headers = CSV.read(CSV_PATH, headers: true).headers
headers << "split_pdf" unless headers.include?("split_pdf")
FileUtils.mkdir_p(OUTPUT_DIR)

written = 0
rows.group_by { |row| row["source_pdf"].to_s }.each do |relative_pdf, records|
  next if relative_pdf.empty?
  source = File.join(DATA, relative_pdf)
  raise "missing source PDF: #{source}" unless File.file?(source)

  page_text, status = Open3.capture2("qpdf", "--show-npages", source)
  raise "cannot count pages: #{source}" unless status.success?
  page_count = Integer(page_text.strip, 10)
  ordered = records.sort_by { |row| Integer(row["pdf_page"], 10) }

  ordered.each_with_index do |row, index|
    id = row["petition_id"].to_s.match(/\A(\d+)陳情第(\d+)号\z/)
    next unless id
    first = Integer(row["pdf_page"], 10)
    last = index + 1 < ordered.length ? Integer(ordered[index + 1]["pdf_page"], 10) - 1 : page_count
    raise "invalid page range #{first}-#{last}: #{relative_pdf}" unless first.between?(1, page_count) && last.between?(first, page_count)

    filename = format("r%02d_petition_%04d.pdf", id[1].to_i, id[2].to_i)
    output = File.join(OUTPUT_DIR, filename)
    range = first == last ? first.to_s : "#{first}-#{last}"
    unless system("qpdf", "--deterministic-id", source, "--pages", ".", range, "--", output,
                  out: File::NULL, err: File::NULL)
      raise "qpdf failed: #{relative_pdf} pages #{range}"
    end
    row["split_pdf"] = "split/#{filename}"
    written += 1
  end
end

CSV.open(CSV_PATH, "w", write_headers: true, headers: headers) do |csv|
  rows.each { |row| csv << headers.map { |header| row[header] } }
end
warn "wrote #{written} split petition PDFs to #{OUTPUT_DIR}"
