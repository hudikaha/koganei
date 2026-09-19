RUBY ?= ruby
NODE ?= node
CURL ?= curl
REMOTE ?= fujikawa.org
REMOTE_DIR ?= fujikawa/koganei/kessan
PUBLIC_URL ?= https://fujikawa.org/koganei/kessan/
RELEASE_FILES ?= kessan/build.rb kessan/Makefile kessan/AGENTS.md
DETAIL_PDFS = \
	03.一般歳入事項別明細書.pdf 04.一般歳出事項別明細書.pdf \
	03.国保歳入事項別明細書.pdf 04.国保歳出事項別明細書.pdf \
	03.介護歳入事項別明細書.pdf 04.介護歳出事項別明細書.pdf \
	03.後期高齢歳入事項別明細書.pdf 04.後期高齢歳出事項別明細書.pdf

.PHONY: all clean check deploy upload deploy-dry-run verify-live publish release

all: index.html

index.html data.json: build.rb $(wildcard *.pdf)
	$(RUBY) build.rb

check: index.html
	$(RUBY) -c build.rb
	$(RUBY) -rjson -e 'd=JSON.parse(File.read("data.json")); abort "no accounts" if d["accounts"].empty?; puts "accounts=#{d["accounts"].length} nodes=#{d["node_count"]}"'
	sed -n '/    <script>$$/,/    <\/script>/p' index.html | sed '1d;$$d' | $(NODE) --check -
	$(RUBY) -e 's=File.read("index.html"); %w[type="checkbox" businessBreakdown setLocation].each { |x| abort "missing #{x}" unless s.include?(x) }; abort "normal success message is visible" if s.include?("一致しています")'

clean:
	rm -f index.html data.json

upload:
	ssh $(REMOTE) mkdir -p $(REMOTE_DIR)
	rsync -a --checksum index.html data.json $(DETAIL_PDFS) $(REMOTE):$(REMOTE_DIR)/

deploy: check upload

deploy-dry-run: check
	ssh $(REMOTE) mkdir -p $(REMOTE_DIR)
	rsync -ani --checksum index.html data.json $(DETAIL_PDFS) $(REMOTE):$(REMOTE_DIR)/

verify-live:
	$(CURL) --max-time 30 -fsS $(PUBLIC_URL) | $(RUBY) -e 's=$$stdin.read; %w[type="checkbox" businessBreakdown setLocation].each { |x| abort "public page missing #{x}" unless s.include?(x) }; puts "public page verified"'

publish:
	$(MAKE) clean
	$(MAKE) check
	$(MAKE) upload
	$(MAKE) verify-live

release: publish
	@test -n "$(MSG)" || { echo 'usage: make release MSG="commit message"'; exit 2; }
	git -C .. diff --check
	git -C .. add $(RELEASE_FILES)
	git -C .. commit -m "$(MSG)"
	git -C .. push
	@tag=$$(date +%Y%m%d%H%M); git -C .. tag "$$tag"; git -C .. push origin "$$tag"; echo "tag=$$tag"
