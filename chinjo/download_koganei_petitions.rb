#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "csv"
require "fileutils"
require "net/http"
require "uri"

BASE = "https://www.city.koganei.lg.jp"
ROOT = File.expand_path("koganei_petitions", __dir__)

INDEXES = {
  2021 => "/shisei/gikaijimukyoku/teireirinji/reiwa3_gikai/reiwa3_seigan/index.html",
  2022 => "/shisei/gikaijimukyoku/teireirinji/seiwa4_gikai/reiwa4_seigan/index.html",
  2023 => "/shisei/gikaijimukyoku/teireirinji/reiwa5_gikai/seigantinzyou/index.html",
  2024 => "/shisei/gikaijimukyoku/teireirinji/reiwa6_gikai/seigantinzyou/index.html",
  2025 => "/shisei/gikaijimukyoku/teireirinji/reiwa7_gikai/seigantinzyou/index.html",
  2026 => "/shisei/gikaijimukyoku/teireirinji/reiwa8_gikai/seigantinzyou/index.html"
}.freeze

def fetch(url, limit = 5)
  raise "too many redirects: #{url}" if limit.zero?

  uri = URI(url)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    http.request(Net::HTTP::Get.new(uri.request_uri, { "User-Agent" => "Mozilla/5.0" }))
  end
  return fetch(URI.join(url, response["location"]).to_s, limit - 1) if response.is_a?(Net::HTTPRedirection)
  raise "HTTP #{response.code}: #{url}" unless response.is_a?(Net::HTTPSuccess)

  response.body
end

def links(html, base_url)
  html.scan(/<a\b[^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/im).map do |href, label|
    next if href.start_with?("javascript:", "#")

    [URI.join(base_url, CGI.unescapeHTML(href)).to_s,
     CGI.unescapeHTML(label.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip)]
  end.compact
end

FileUtils.mkdir_p(ROOT)
records = []
name_counts = Hash.new(0)
old_paths = {}
old_manifest = File.join(ROOT, "manifest.tsv")
if File.file?(old_manifest)
  CSV.foreach(old_manifest, headers: true, col_sep: "\t") do |row|
    old_paths[row["source_url"]] = File.join(__dir__, row["local_path"].to_s)
  end
end

def local_basename(label, source_url, name_counts)
  match = label.match(/令和\s*(\d+)年\s*(\d+)月\s*(\d+)日/)
  date = if match
           format("%04d%02d%02d", 2018 + match[1].to_i, match[2].to_i, match[3].to_i)
         else
           File.basename(URI(source_url).path, ".pdf").gsub(/[^a-zA-Z0-9]+/, "_").downcase
         end
  numbers = label.scan(/陳情第\s*(\d+)号/).flatten.map(&:to_i)
  kind = if label.include?("訂正")
           "correction"
         elsif label.match?(/差替|差し替/)
           "replacement"
         else
           "petitions"
         end
  range = if numbers.length >= 2
            format("_%04d-%04d", numbers.first, numbers.last)
          elsif numbers.length == 1
            format("_%04d", numbers.first)
          else
            ""
          end
  key = [date, kind, range]
  name_counts[key] += 1
  suffix = if range.empty? && kind == "petitions"
             format("_batch%02d", name_counts[key])
           elsif name_counts[key] > 1
             format("_batch%02d", name_counts[key])
           else
             ""
           end
  "#{date}_#{kind}#{range}#{suffix}.pdf"
end

INDEXES.each do |year, index_path|
  index_url = URI.join(BASE, index_path).to_s
  index_html = fetch(index_url).force_encoding(Encoding::UTF_8)
  pages = links(index_html, index_url).select do |url, label|
    url.end_with?(".html") && label.match?(/第\d+回(?:定例会|臨時会)/)
  end

  pages.each do |page_url, meeting|
    page_html = fetch(page_url).force_encoding(Encoding::UTF_8)
    pdfs = links(page_html, page_url).select { |url, _label| url.downcase.end_with?(".pdf") }
    pdfs.each_with_index do |(pdf_url, label), index|
      filename = local_basename(label, pdf_url, name_counts)
      path = File.join(ROOT, year.to_s, filename)
      FileUtils.mkdir_p(File.dirname(path))
      previous = old_paths[pdf_url]
      if !File.exist?(path) && previous && File.file?(previous)
        previous_stem = File.basename(previous, ".pdf")
        new_stem = File.basename(path, ".pdf")
        FileUtils.mv(previous, path)
        %w[images text].each do |generated|
          previous_dir = File.join(ROOT, generated, year.to_s, previous_stem)
          new_dir = File.join(ROOT, generated, year.to_s, new_stem)
          FileUtils.mv(previous_dir, new_dir) if File.directory?(previous_dir) && !File.exist?(new_dir)
        end
        warn "renamed #{previous} -> #{path}"
      end
      if File.file?(path) && File.binread(path, 5) == "%PDF-"
        bytes = File.size(path)
      else
        data = fetch(pdf_url)
        raise "not a PDF: #{pdf_url}" unless data.start_with?("%PDF-")

        File.binwrite(path, data)
        bytes = data.bytesize
        warn "saved #{path}"
      end
      records << [year, meeting, label, pdf_url, path.delete_prefix(__dir__ + "/"), bytes]
    end
  end
end

CSV.open(File.join(ROOT, "manifest.tsv"), "w", col_sep: "\t") do |csv|
  csv << %w[year meeting description source_url local_path bytes]
  records.each { |record| csv << record }
end

warn "downloaded #{records.length} PDFs"
