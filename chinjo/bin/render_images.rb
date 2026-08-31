#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "open3"

ROOT = File.expand_path("..", __dir__)
DATA = File.join(ROOT, "koganei_petitions")
DPI = Integer(ENV.fetch("DPI", "300"))

CSV.foreach(File.join(DATA, "manifest.tsv"), headers: true, col_sep: "\t") do |row|
  pdf = File.join(ROOT, row.fetch("local_path"))
  year = row.fetch("year")
  stem = File.basename(pdf, ".pdf")
  output_dir = File.join(DATA, "images", year, stem)
  pages_text, status = Open3.capture2("pdfinfo", pdf)
  raise "pdfinfo failed: #{pdf}" unless status.success?
  page_count = Integer(pages_text[/^Pages:\s+(\d+)/, 1])
  existing = Dir.glob(File.join(output_dir, "p*.png"))
  next if existing.length == page_count

  FileUtils.mkdir_p(output_dir)
  temporary = File.join(output_dir, "render")
  system("pdftoppm", "-png", "-gray", "-r", DPI.to_s, pdf, temporary, exception: true)
  Dir.glob("#{temporary}-*.png").each do |source|
    number = Integer(source[/-(\d+)\.png\z/, 1], 10)
    FileUtils.mv(source, File.join(output_dir, format("p%04d.png", number)))
  end
  actual = Dir.glob(File.join(output_dir, "p*.png")).length
  raise "page count mismatch for #{pdf}: #{actual}/#{page_count}" unless actual == page_count
  warn "rendered #{year}/#{stem}: #{actual} pages"
end
