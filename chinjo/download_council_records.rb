#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "csv"
require "digest"
require "fileutils"
require "net/http"
require "uri"

BASE = "https://www.city.koganei.lg.jp"
ROOT = File.expand_path("koganei_petitions/references", __dir__)

RESULT_INDEXES = {
  2021 => "/shisei/gikaijimukyoku/teireirinji/reiwa3_gikai/reiwa3_shingi/index.html",
  2022 => "/shisei/gikaijimukyoku/teireirinji/seiwa4_gikai/reiwa4_shingi/index.html",
  2023 => "/shisei/gikaijimukyoku/teireirinji/reiwa5_gikai/reiwa5_shing/index.html",
  2024 => "/shisei/gikaijimukyoku/teireirinji/reiwa6_gikai/reiwa6_shing/index.html",
  2025 => "/shisei/gikaijimukyoku/teireirinji/reiwa7_gikai/reiwa7_shing/index.html",
  2026 => "/shisei/gikaijimukyoku/teireirinji/reiwa8_gikai/reiwa8_shing/index.html"
}.freeze

NEWSLETTER_INDEXES = (2021..2026).to_h do |year|
  reiwa = year - 2018
  [year, "/shisei/gikaijimukyoku/koutyou_koho/sigikaidayoripdf/r#{reiwa}/index.html"]
end.freeze

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
  html.force_encoding(Encoding::UTF_8)
      .scan(/<a\b[^>]*href=["']([^"']+)["'][^>]*>(.*?)<\/a>/im)
      .filter_map do |href, label|
        next if href.start_with?("javascript:", "#")

        [URI.join(base_url, CGI.unescapeHTML(href)).to_s,
         CGI.unescapeHTML(label.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip)]
      end
end

def safe(value)
  cleaned = value.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
  cleaned.empty? ? "page" : cleaned
end

FileUtils.mkdir_p(ROOT)
records = []

{
  "results" => RESULT_INDEXES,
  "newsletters" => NEWSLETTER_INDEXES
}.each do |kind, indexes|
  indexes.each do |year, index_path|
    index_url = URI.join(BASE, index_path).to_s
    index_html = fetch(index_url)
    prefix = File.dirname(index_url) + "/"
    child_pages = links(index_html, index_url).select do |url, label|
      url.start_with?(prefix) && url.end_with?(".html") && !label.empty?
    end.uniq { |url, _label| url }

    child_pages.each do |page_url, page_label|
      page_html = fetch(page_url)
      page_slug = safe(File.basename(URI(page_url).path, ".html"))
      pdf_links = links(page_html, page_url).select { |url, _label| url.downcase.end_with?(".pdf") }
      if kind == "newsletters"
        pdf_links.select! { |_url, label| label.match?(/陳情|審議未了/) }
      end
      pdf_links.each do |pdf_url, pdf_label|
        basename = safe(File.basename(URI(pdf_url).path, ".pdf"))
        filename = "#{page_slug}__#{basename}.pdf"
        path = File.join(ROOT, kind, year.to_s, filename)
        FileUtils.mkdir_p(File.dirname(path))
        unless File.file?(path) && File.binread(path, 5) == "%PDF-"
          data = fetch(pdf_url)
          raise "not a PDF: #{pdf_url}" unless data.start_with?("%PDF-")
          File.binwrite(path, data)
          warn "saved #{path}"
        end
        records << [kind, year, page_label, pdf_label, pdf_url, path.delete_prefix(File.dirname(ROOT) + "/")]
      end
    end
  end
end

newsletter_keep = records.select { |record| record[0] == "newsletters" }
                         .map { |record| File.join(File.dirname(ROOT), record[5]) }
Dir.glob(File.join(ROOT, "newsletters", "*", "*.pdf")).each do |path|
  FileUtils.rm_f(path) unless newsletter_keep.include?(path)
end

CSV.open(File.join(ROOT, "manifest.tsv"), "w", col_sep: "\t") do |csv|
  csv << %w[kind year meeting description source_url local_path]
  records.uniq.each { |record| csv << record }
end
warn "downloaded/indexed #{records.uniq.length} reference PDFs"
