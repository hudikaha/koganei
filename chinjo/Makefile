RUBY := ruby
DPI ?= 300
JOBS ?= 4
PUBLISH_DIR ?= publish/chinjo
REMOTE ?= fujikawa.org
REMOTE_DIR ?= fujikawa/koganei/chinjo
RSYNC_FLAGS ?= -a --checksum --delete --itemize-changes --no-times --omit-dir-times

.PHONY: all prepare status \
	deploy-dry-run deploy \
	download references official-results \
	images ocr-models ocr vision-ocr \
	csv audit-titles check-titles split-pdfs html \
	clean-generated

# Standard local release build. Heavy network/OCR work stays opt-in.
all: prepare

prepare:
	$(MAKE) csv
	$(MAKE) split-pdfs
	$(MAKE) html
	$(RUBY) bin/build_publish.rb $(PUBLISH_DIR)

# Compact handoff check; distinguishes linked artifacts from stale files that
# may remain in persistent generated directories.
status:
	$(RUBY) -rcsv -e 'rows = CSV.read("koganei_petitions/petitions.csv", headers: true); puts "petitions=#{rows.size}"; puts "linked_split=#{rows.count { |row| !row["split_pdf"].to_s.empty? }}"; puts "split_files=#{Dir.glob("koganei_petitions/split/*.pdf").size}"; puts "images=#{Dir.glob("koganei_petitions/images/**/*.png").size}"; puts "newsletters=#{Dir.glob("koganei_petitions/references/newsletters/**/*.pdf").size}"; puts "results=#{Dir.glob("koganei_petitions/references/results/**/*.pdf").size}"'

# Network acquisition targets.
download:
	$(RUBY) download_koganei_petitions.rb

references:
	$(RUBY) download_council_records.rb

official-results:
	$(RUBY) bin/extract_official_results.rb

# Durable page images and OCR. These are intentionally not prerequisites of all.
images:
	DPI=$(DPI) $(RUBY) bin/render_images.rb

ocr-models: tools/tessdata/jpn_best.traineddata tools/tessdata/jpn_vert.traineddata

tools/tessdata/jpn_best.traineddata:
	mkdir -p tools/tessdata
	curl -L --fail https://github.com/tesseract-ocr/tessdata_best/raw/refs/heads/main/jpn.traineddata -o $@

tools/tessdata/jpn_vert.traineddata:
	mkdir -p tools/tessdata
	curl -L --fail https://github.com/tesseract-ocr/tessdata_best/raw/refs/heads/main/jpn_vert.traineddata -o $@

ocr: ocr-models
	JOBS=$(JOBS) $(RUBY) bin/ocr_pages.rb

bin/vision_ocr: bin/vision_ocr.m
	xcrun clang -fobjc-arc -framework Foundation -framework AppKit -framework Vision $< -o $@

vision-ocr: bin/vision_ocr
	ALL=1 $(RUBY) bin/build_vision_list.rb
	./bin/vision_ocr koganei_petitions/vision_images.txt

# Normal index regeneration, in required order.
csv: official-results
	$(RUBY) bin/extract_petitions.rb
	$(RUBY) bin/audit_missing_petitions.rb
	$(RUBY) bin/reconcile_petitions.rb
	$(RUBY) bin/audit_titles.rb --check

audit-titles:
	$(RUBY) bin/audit_titles.rb

check-titles:
	$(RUBY) bin/audit_titles.rb --check

split-pdfs:
	$(RUBY) bin/split_petition_pdfs.rb

html:
	$(RUBY) bin/csv_to_html.rb

# Publication. Always inspect deploy-dry-run before deploy.
deploy-dry-run: prepare
	ssh $(REMOTE) mkdir -p $(REMOTE_DIR)
	rsync $(RSYNC_FLAGS) --dry-run $(PUBLISH_DIR)/ $(REMOTE):$(REMOTE_DIR)/

deploy: prepare
	ssh $(REMOTE) mkdir -p $(REMOTE_DIR)
	rsync $(RSYNC_FLAGS) $(PUBLISH_DIR)/ $(REMOTE):$(REMOTE_DIR)/

# Generated source material is persistent by policy; this target deletes nothing.
clean-generated:
	@echo 'Generated images, OCR, CSV, and HTML are intentionally persistent.'
	@echo 'Remove a specific generated directory manually if regeneration is required.'
