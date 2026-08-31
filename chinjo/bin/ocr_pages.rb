#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "thread"

ROOT = File.expand_path("..", __dir__)
DATA = File.join(ROOT, "koganei_petitions")
TESSDATA = File.join(ROOT, "tools", "tessdata")
JOBS = Integer(ENV.fetch("JOBS", "4"))

images = Dir.glob(File.join(DATA, "images", "*", "*", "p*.png")).sort
queue = Queue.new
images.each { |image| queue << image }

workers = Array.new(JOBS) do
  Thread.new do
    loop do
      image = queue.pop(true)
      relative = image.delete_prefix(File.join(DATA, "images") + "/")
      output = File.join(DATA, "text", relative.sub(/\.png\z/, ".txt"))
      next if File.file?(output) && File.size?(output)

      FileUtils.mkdir_p(File.dirname(output))
      stdout, stderr, status = Open3.capture3(
        "tesseract", File.basename(image), "stdout", "-l", "jpn_best",
        "--tessdata-dir", TESSDATA, "--psm", "3", chdir: File.dirname(image)
      )
      raise "OCR failed for #{image}: #{stderr}" unless status.success?
      File.write(output, stdout, encoding: Encoding::UTF_8)
      warn "ocr #{relative}"
    rescue ThreadError
      break
    end
  end
end
workers.each(&:join)
