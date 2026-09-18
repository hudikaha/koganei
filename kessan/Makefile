RUBY ?= ruby
REMOTE ?= fujikawa.org
REMOTE_DIR ?= fujikawa/koganei/kessan
DETAIL_PDFS = \
	03.一般歳入事項別明細書.pdf 04.一般歳出事項別明細書.pdf \
	03.国保歳入事項別明細書.pdf 04.国保歳出事項別明細書.pdf \
	03.介護歳入事項別明細書.pdf 04.介護歳出事項別明細書.pdf \
	03.後期高齢歳入事項別明細書.pdf 04.後期高齢歳出事項別明細書.pdf

.PHONY: all clean check deploy deploy-dry-run

all: index.html

index.html data.json: build.rb $(wildcard *.pdf)
	$(RUBY) build.rb

check: index.html
	$(RUBY) -c build.rb
	$(RUBY) -rjson -e 'd=JSON.parse(File.read("data.json")); abort "no accounts" if d["accounts"].empty?; puts "accounts=#{d["accounts"].length} nodes=#{d["node_count"]}"'

clean:
	rm -f index.html data.json

deploy: check
	ssh $(REMOTE) mkdir -p $(REMOTE_DIR)
	rsync -a --checksum index.html data.json $(DETAIL_PDFS) $(REMOTE):$(REMOTE_DIR)/

deploy-dry-run: check
	ssh $(REMOTE) mkdir -p $(REMOTE_DIR)
	rsync -ani --checksum index.html data.json $(DETAIL_PDFS) $(REMOTE):$(REMOTE_DIR)/
