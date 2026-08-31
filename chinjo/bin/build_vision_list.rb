#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"

root = File.expand_path("..", __dir__)
data = File.join(root, "koganei_petitions")
paths = if ENV["ALL"] == "1"
          Dir.glob(File.join(data, "images", "*", "*", "p*.png")).sort
        else
          CSV.read(File.join(data, "petitions.csv"), headers: true)
             .map { |row| File.join(data, row.fetch("image_path")) }
             .uniq
        end
File.write(File.join(data, "vision_images.txt"), paths.join("\n") + "\n")
warn "wrote #{paths.length} image paths"
