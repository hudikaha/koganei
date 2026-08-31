#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "pathname"

root = File.expand_path("..", __dir__)
data = File.join(root, "koganei_petitions")
destination = File.expand_path(ARGV.fetch(0, File.join(root, "publish", "chinjo")), root)
publish_root = File.join(root, "publish")
unless destination.start_with?(publish_root + File::SEPARATOR)
  abort "publish destination must be below #{publish_root}: #{destination}"
end

index = File.join(data, "index.html")
csv = File.join(data, "petitions.csv")
abort "missing #{index}; run make html" unless File.file?(index)
abort "missing #{csv}; run make csv" unless File.file?(csv)

links = File.read(index).scan(/href="([^"]+)"/).flatten.uniq
links.reject! { |path| path.match?(%r{\A(?:[a-z]+:|#)}) }

FileUtils.rm_rf(destination)
FileUtils.mkdir_p(destination)
FileUtils.cp(index, File.join(destination, "index.html"))
FileUtils.cp(csv, File.join(destination, "petitions.csv"))

links.each do |relative|
  clean = Pathname(relative).cleanpath.to_s
  abort "unsafe link in index.html: #{relative}" if clean.start_with?("../") || Pathname(clean).absolute?
  source = File.join(data, clean)
  abort "broken local link in index.html: #{relative}" unless File.file?(source)
  target = File.join(destination, clean)
  FileUtils.mkdir_p(File.dirname(target))
  FileUtils.cp(source, target)
end

warn "staged index, CSV, and #{links.length} linked files in #{destination}"
