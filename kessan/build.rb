#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "json"
require "open3"

ROOT = __dir__
ACCOUNTS = {
  "一般会計" => ["一般", "general"],
  "国民健康保険特別会計" => ["国保", "national-health"],
  "介護保険特別会計" => ["介護", "nursing-care"],
  "後期高齢者医療特別会計" => ["後期高齢", "late-elderly"]
}.freeze

def compact_name(value)
  value.to_s.gsub(/[[:space:]　]+/, "").sub(/[（(].*\z/, "").strip
end

def amount_values(value)
  value.scan(/(?:△|-)?\s*\d[\d,]*/).map do |raw|
    negative = raw.include?("△") || raw.lstrip.start_with?("-")
    number = raw.gsub(/[^\d]/, "").to_i
    negative ? -number : number
  end
end

def extract_text(pdf)
  output, status = Open3.capture2("pdftotext", "-layout", pdf, "-")
  abort "pdftotext failed: #{pdf}" unless status.success?
  output
end

def extract_tsv_rows(pdf)
  output, status = Open3.capture2("pdftotext", "-tsv", pdf, "-")
  abort "pdftotext TSV failed: #{pdf}" unless status.success?
  pages = Hash.new { |hash, key| hash[key] = [] }
  output.each_line do |line|
    fields = line.chomp.split("\t", 12)
    next unless fields.length == 12 && fields[0] == "5"
    page = fields[1].to_i
    x = fields[6].to_f
    top = fields[7].to_f
    next if fields[11].start_with?("###")
    pages[page] << [top, x, fields[11]]
  end
  pages.sort.flat_map do |page, words|
    rows = []
    words.sort_by(&:first).each do |top, x, text|
      row = rows.reverse.find { |candidate| (candidate[0] - top).abs <= 0.35 }
      if row
        row[1] << [x, text]
      else
        rows << [top, [[x, text]]]
      end
    end
    rows.sort_by(&:first).map { |top, row_words| [page, top, row_words.sort_by(&:first)] }
  end
end

def row_parts(line, kind)
  line = line.chomp
  match = line.match(/\A(\s*)((?:\d+\s+)*)(\d+)\s*([^\d\s].*?)\s{2,}((?:△|-)?\s*\d[\d,].*)\z/)
  return unless match

  indent = match[1].length
  codes = match[2].scan(/\d+/).map(&:to_i) + [match[3].to_i]
  return if codes.length == 1 && indent >= 140
  return if codes.length.between?(2, 3) && match.begin(4) > 40
  return if codes.length >= 4 && match.begin(4) >= 140
  level = if codes.length > 1
            codes.length
          elsif indent < 2
            1
          elsif indent < 6
            2
          elsif indent < 50
            3
          else
            4
          end
  raw_name = match[4]
  values = amount_values(match[5])
  swallowed_values = []
  while (swallowed = raw_name.match(/\A(.*?\S)\s{2,}((?:△|-)?\s*\d[\d,]*)\z/))
    raw_name = swallowed[1]
    swallowed_values.unshift(amount_values(swallowed[2]).first)
  end
  values = swallowed_values + values
  amount = if kind == :revenue
             level == 4 ? values[2] : values[5]
           else
             level == 4 ? values[1] : values[5]
           end
  return unless amount

  [level, codes.last, compact_name(raw_name), amount, match.begin(4), codes.length > 1]
end

def parse_statement(pdf, kind, account_id)
  roots = []
  stack = []
  sequence = 0
  pending = nil
  extract_text(pdf).each_line do |line|
    parts = row_parts(line, kind)
    unless parts
      if line.strip.empty?
        pending = nil
      else
        if pending && (leading = line.index(/\S/)) && leading.between?(pending[:column] - 2, pending[:column] + 10)
          fragment = line[leading, 60].to_s.sub(/\s{2,}.*\z/, "")
          addition = compact_name(fragment)
          unless addition.empty? || addition.match?(/[,円％]/)
            pending[:node]["name"] << addition
            next
          end
        end
        pending = nil
      end
      next
    end
    level, code, name, amount, name_column = parts
    next if name.empty?

    sequence += 1
    node = {
      "id" => "#{account_id}-#{kind}-#{sequence}",
      "code" => code,
      "name" => name,
      "amount" => amount,
      "level" => level,
      "children" => [],
      "details" => []
    }
    stack = stack.take(level - 1)
    if level == 1
      roots << node
    elsif stack[level - 2]
      stack[level - 2]["children"] << node
    else
      next
    end
    stack[level - 1] = node
    pending = { node: node, column: name_column }
  end
  roots
end

def attach_details(pdf, kind, roots)
  queues = Hash.new { |hash, key| hash[key] = [] }
  collect = lambda do |nodes|
    nodes.each do |node|
      queues[node["level"]] << node
      collect.call(node["children"])
    end
  end
  collect.call(roots)
  stack = []
  buffer = nil
  buffer_number = nil

  extract_text(pdf).split("\f").each do |page_text|
    source_page = page_text.scan(/[-－]\s*(\d+)\s*[-－]/).flatten.map(&:to_i).max
    page_text.each_line do |line|
    if (parts = row_parts(line, kind))
      level = parts[0]
      if (node = queues[level].shift)
        stack = stack.take(level - 1)
        stack[level - 1] = node
      end
    end

    if kind == :revenue
      right = line[180..].to_s.strip
      next if right.empty?
      match = right.match(/\A(.+?)\s+((?:△|-)?\d[\d,]*)\s*\z/)
      next unless match
      text = match[1].gsub(/[[:space:]　]+/, " ").strip.sub(/\A(?:[,\d]+\s+)+/, "")
      next if text.empty? || text.match?(/\A[\d.,()（）]+\z/)
      target = stack[3] || stack[2]
      next unless target
      detail = { "name" => text, "amount" => amount_values(match[2]).first }
      target["details"] << detail unless target["details"].include?(detail)
      next
    end

    # Only rows with a responsible department are project summaries.  Japanese
    # wide characters make Ruby character offsets differ from pdftotext's
    # visual columns, so anchor at the department and take the last numbered
    # item before it instead of slicing at a guessed character position.
    # Department labels are often shortened to fit the column (for example,
    # "子育て支援"), so do not require a conventional 「○○課」 suffix.
    # Digits and commas are excluded to distinguish these labels from the
    # parenthesized totals used by section rows.
    department = /[（(]\s*([^\d,）)]*)\s*[）)]\s+([\d,]+)\s*\z/
    if (match = line.match(/#{department}/)) && buffer
      prefix = line[0...match.begin(0)].to_s.split(/\s{3,}/).last.to_s.strip
      text = (buffer + prefix).gsub(/[[:space:]　]+/, " ").strip
      unless text.empty?
        detail = { "number" => buffer_number, "name" => text, "department" => compact_name(match[1]), "amount" => amount_values(match[2]).first, "page" => source_page }
        target = stack[2]
        target["details"] << detail if target && !target["details"].include?(detail)
      end
      buffer = nil
      buffer_number = nil
    elsif (match = line.match(/.*\s(\d+)\s+([^\d].*?)\s+#{department}/))
      text = match[2].gsub(/[[:space:]　]+/, " ").strip
      next if text.empty? || text.match?(/\A[,\d()（）]/)
      detail = { "number" => match[1].to_i, "name" => text, "department" => compact_name(match[3]), "amount" => amount_values(match[4]).first, "page" => source_page }
      target = stack[2]
      target["details"] << detail if target && !target["details"].include?(detail)
      buffer = nil
      buffer_number = nil
    elsif (start = (tail = line.rstrip.split(/\s{3,}/).last.to_s.strip).match(/\A(\d+)\s+([^\d(].*)\z/))
      buffer_number = start[1].to_i
      buffer = start[2]
    elsif buffer && !tail.empty? && !tail.match?(/[\d()（）]/)
      buffer << tail
    else
      buffer = nil
      buffer_number = nil
    end
    end
  end
end

def attach_expense_breakdowns(pdf, roots)
  projects = Hash.new { |hash, key| hash[key] = [] }
  visit = lambda do |nodes|
    nodes.each do |node|
      node["details"].each do |detail|
        detail["sections"] = []
        projects[[compact_name(detail["name"]), detail["amount"]]] << detail
      end
      visit.call(node["children"])
    end
  end
  visit.call(roots)

  current_project = nil
  current_section = nil
  project_name = nil
  item_name = nil

  extract_tsv_rows(pdf).each do |_page, _top, words|
    right = words.select { |x, _| x >= 945 }
    next if right.empty?
    first_x, first_text = right.first

    if first_x.between?(945, 960) && first_text.match?(/\A\d+\z/)
      project_name = right.select { |x, text| x > first_x && x < 1057 && text !~ /[()（）]/ }.map(&:last).join
      current_project = nil
      current_section = nil
      item_name = nil
    elsif project_name
      project_name << right.select { |x, text| x.between?(960, 1056) && text !~ /[()（）]/ }.map(&:last).join
    end

    if project_name && right.any? { |x, text| x.between?(1050, 1120) && text.include?("(") } &&
       right.any? { |x, text| x.between?(1050, 1120) && text.include?(")") }
      amount_text = right.select { |x, text| x >= 1120 && text.match?(/[\d,]/) }.map(&:last).join
      amount = amount_values(amount_text).first
      key = [compact_name(project_name), amount]
      current_project = projects[key].shift if amount
      project_name = nil
      current_section = nil
      item_name = nil
      next
    end

    section_number = right.find { |x, text| x.between?(972, 986) && text.match?(/\A\d+\z/) }
    if current_project && section_number && right.any? { |x, text| x >= 1090 && text.include?("(") }
      name = right.select { |x, text| x >= 987 && x < 1090 && text !~ /[()（）]/ }.map(&:last).join
      amount_text = right.select { |x, text| x >= 1120 && text.match?(/[\d,]/) }.map(&:last).join
      amount = amount_values(amount_text).first
      if !name.empty? && amount
        current_section = { "number" => section_number[1].to_i, "name" => name, "amount" => amount, "items" => [] }
        current_project["sections"] << current_section
      end
      item_name = nil
      next
    end

    next unless current_section
    label = right.select { |x, text| x >= 990 && x < 1120 && !text.match?(/\A[()（）]\z/) }.map(&:last).join
    amount_text = right.select { |x, text| x >= 1120 && text.match?(/[\d,]/) }.map(&:last).join
    amount = amount_values(amount_text).first
    if amount && (!label.empty? || item_name)
      name = [item_name, label].compact.join
      current_section["items"] << { "name" => name, "amount" => amount } unless name.empty?
      item_name = nil
    elsif !label.empty? && !label.match?(/\A\d+(?:需用費|役務費|委託料|扶助費|報酬|旅費)/)
      item_name = [item_name, label].compact.join
    end
  end

  projects.each_value do |details|
    details.each { |detail| detail.delete("sections") if detail["sections"].empty? }
  end
  checker = lambda do |nodes|
    nodes.each do |node|
      node["details"].each do |detail|
        next unless detail["sections"]
        detail["sections"].each do |section|
          section["item_total"] = section["items"].sum { |item| item["amount"] }
          section["item_difference"] = section["item_total"] - section["amount"]
        end
        detail["section_total"] = detail["sections"].sum { |section| section["amount"] }
        detail["section_difference"] = detail["section_total"] - detail["amount"]
      end
      checker.call(node["children"])
    end
  end
  checker.call(roots)
end

def page_map(pdf, kind, roots)
  queues = Hash.new { |hash, key| hash[key] = [] }
  collect = lambda do |nodes|
    nodes.each do |node|
      queues[node["level"]] << node
      collect.call(node["children"])
    end
  end
  collect.call(roots)
  mapping = {}
  extract_text(pdf).split("\f").each do |page|
    first_new = nil
    first_any = nil
    page_nodes = []
    page.each_line do |line|
      next unless (parts = row_parts(line, kind))
      level, = parts
      continued = parts[5]
      node = queues[level].shift
      next unless node
      page_nodes << node
      first_any ||= node
      first_new ||= node if level <= 3 && !continued
    end
    printed_pages = page.scan(/[-－]\s*(\d+)\s*[-－]/).flatten.map(&:to_i).uniq
    page_nodes.each { |node| node["page"] ||= printed_pages.min } unless printed_pages.empty?
    target = first_new || first_any
    next unless target
    printed_pages.each do |printed_page|
      mapping[printed_page.to_s] = target["id"]
    end
  end
  mapping
end

accounts = ACCOUNTS.map do |name, (prefix, id)|
  revenue_pdf = Dir[File.join(ROOT, "03.#{prefix}歳入事項別明細書.pdf")].first
  expense_pdf = Dir[File.join(ROOT, "04.#{prefix}歳出事項別明細書.pdf")].first
  abort "missing statements for #{name}" unless revenue_pdf && expense_pdf
  revenue = parse_statement(revenue_pdf, :revenue, id)
  expense = parse_statement(expense_pdf, :expense, id)
  attach_details(revenue_pdf, :revenue, revenue)
  attach_details(expense_pdf, :expense, expense)
  attach_expense_breakdowns(expense_pdf, expense)
  {
    "id" => id,
    "name" => name,
    "revenue" => revenue,
    "expense" => expense,
    "pages" => {
      "revenue" => page_map(revenue_pdf, :revenue, revenue),
      "expense" => page_map(expense_pdf, :expense, expense)
    },
    "sources" => {
      "revenue" => File.basename(revenue_pdf),
      "expense" => File.basename(expense_pdf)
    }
  }
end

def validate_totals(nodes, trail)
  nodes.each do |node|
    next if node["children"].empty?
    children_total = node["children"].sum { |child| child["amount"] }
    unless children_total == node["amount"]
      abort "amount mismatch: #{(trail + [node['name']]).join(' > ')}: #{node['amount']} != #{children_total}"
    end
    validate_totals(node["children"], trail + [node["name"]])
  end
end

accounts.each do |account|
  %w[revenue expense].each do |kind|
    validate_totals(account[kind], [account["name"], kind])
  end
end

def each_node(nodes, &block)
  nodes.each do |node|
    block.call(node)
    each_node(node["children"], &block)
  end
end

accounts.each do |account|
  each_node(account["expense"]) do |node|
    next unless node["level"] == 3 && node["amount"] != 0
    node["detail_total"] = node["details"].sum { |detail| detail["amount"] }
    node["detail_difference"] = node["detail_total"] - node["amount"]
  end
end

node_count = 0
detail_count = 0
accounts.each do |account|
  %w[revenue expense].each do |kind|
    each_node(account[kind]) do |node|
      node_count += 1
      detail_count += node["details"].length
    end
  end
end

data = {
  "title" => "小金井市 令和7年度決算",
  "generated_at" => Time.now.strftime("%Y-%m-%d %H:%M:%S %z"),
  "node_count" => node_count,
  "detail_count" => detail_count,
  "accounts" => accounts
}
File.write(File.join(ROOT, "data.json"), JSON.pretty_generate(data))

embedded = JSON.generate(data).gsub("</", "<\\/")
html = <<~HTML
  <!doctype html>
  <html lang="ja">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>小金井市 令和7年度決算</title>
    <style>
      :root{font-family:-apple-system,BlinkMacSystemFont,"Yu Gothic",sans-serif;color:#17212b;background:#f4f6f8}
      *{box-sizing:border-box}body{margin:0}header{background:#174f67;color:white;padding:1rem max(1rem,calc((100% - 1180px)/2))}
      h1{font-size:clamp(1.35rem,3vw,2rem);margin:0}header p{margin:.35rem 0 0;color:#dcebf1}
      main{max-width:1180px;margin:auto;padding:1rem}.controls,.panel{background:white;border:1px solid #d7dde2;border-radius:12px;padding:1rem;margin-bottom:1rem}
      .switches{display:flex;gap:.5rem;flex-wrap:wrap;margin-bottom:.8rem}button{font:inherit;border:1px solid #aab6bf;background:white;border-radius:999px;padding:.45rem .8rem;cursor:pointer}
      button.active{background:#174f67;color:white;border-color:#174f67}.search-wrap{position:relative}#search{width:100%;font:inherit;padding:.7rem;border:1px solid #8e9aa3;border-radius:8px}
      #results{position:absolute;z-index:5;left:0;right:0;background:white;border:1px solid #aab6bf;box-shadow:0 5px 18px #0002;max-height:19rem;overflow:auto;display:none}
      #results button{display:block;width:100%;border:0;border-radius:0;text-align:left;padding:.55rem}.result-path{display:block;color:#5c6972;font-size:.78rem}
      .page-jump{display:flex;gap:.5rem;align-items:center;flex-wrap:wrap;margin-top:.8rem}.page-jump label{font-size:.9rem}.page-jump input{width:9rem;font:inherit;padding:.5rem;border:1px solid #8e9aa3;border-radius:8px}.page-jump .status{font-size:.85rem;color:#68757e}
      #breadcrumbs{display:flex;gap:.35rem;align-items:center;flex-wrap:wrap;margin-bottom:.7rem}#breadcrumbs button{border:0;padding:.2rem;background:none;color:#15607e;text-decoration:underline}
      .drill-panel{scroll-margin-top:1rem;padding-top:1rem}.drill-panel+.drill-panel{border-top:3px solid #d7e2e8;margin-top:1.2rem}
      .drill-panel h2{font-size:1.15rem;margin:.2rem 0}.chart-grid{display:grid;grid-template-columns:minmax(300px,1fr) minmax(280px,.9fr);gap:1rem;align-items:start}
      .chart{width:100%;height:auto;max-height:650px}.slice{cursor:pointer;stroke:white;stroke-width:2;transition:opacity .15s,stroke-width .15s}.slice.selected{stroke:#17212b;stroke-width:5}.slice.hovered{stroke:#17212b;stroke-width:4}.chart.has-hover .slice:not(.hovered):not(.selected){opacity:.55}.slice-label{pointer-events:none;font-weight:700;font-size:18px;text-anchor:middle;paint-order:stroke;stroke:white;stroke-width:7px;stroke-linejoin:round}.slice-label .amount,.slice-label .detail-note{font-weight:600;font-size:16px}.slice-label .detail-note{fill:#8a3f00}
      .center-title{font-weight:700;font-size:15px}.center-value{font-size:13px;fill:#52606a}
      .legend{list-style:none;padding:0;margin:0;max-height:620px;overflow:auto}.legend button{display:grid;grid-template-columns:1rem 1fr auto;gap:.5rem;width:100%;border:0;border-radius:7px;text-align:left;align-items:center;padding:.5rem}
      .legend button:hover,.legend button:focus{background:#edf5f8}.swatch{width:.8rem;height:.8rem;border-radius:2px}.money{font-variant-numeric:tabular-nums;white-space:nowrap}.minor{color:#68757e;font-size:.85rem}
      .details{margin-top:1rem;border-top:1px solid #d7dde2;padding-top:.8rem}.details h3{font-size:1rem;margin:.2rem 0 .6rem}.details-list{display:grid;gap:.55rem}.project-detail{border:1px solid #d7dde2;border-radius:8px;padding:.5rem .7rem}.project-detail summary{cursor:pointer;font-weight:600}.section-list,.item-list{margin:.5rem 0 .2rem 1.2rem;padding-left:1rem}.section-list>li{margin:.55rem 0}.item-list li{margin:.2rem 0}.detail-amount{white-space:nowrap;color:#52606a}
      .detail-check{padding:.65rem .8rem;border-radius:8px;margin:.4rem 0 .8rem;font-weight:600}.detail-check.ok{background:#e8f5ec;color:#245c35}.detail-check.warn{background:#fff0d8;color:#7a4300;border:1px solid #e4b866}
      .business-mode{display:flex;gap:1rem;border:0;padding:0;margin:.6rem 0 1rem}.business-mode label{cursor:pointer}.business-mode input{margin-right:.3rem}.business-list{display:grid;gap:.45rem}.business-list details{border:1px solid #d7dde2;border-radius:7px;padding:.45rem .65rem}.business-chart{display:grid;grid-template-columns:minmax(300px,1fr) minmax(280px,.9fr);gap:1rem;align-items:start}
      .empty{text-align:center;padding:4rem 1rem;color:#68757e}.source{margin-top:1rem;font-size:.9rem}a{color:#15607e}
      @media(max-width:760px){.chart-grid{grid-template-columns:1fr}.legend{max-height:none}}
    </style>
  </head>
  <body>
    <header><h1>小金井市 令和7年度決算</h1><p>会計・歳入歳出を選び、円グラフをクリックして内訳を表示</p></header>
    <main>
      <section class="controls">
        <div id="accounts" class="switches" aria-label="会計"></div>
        <div id="kinds" class="switches" aria-label="歳入歳出"></div>
        <div class="search-wrap"><input id="search" type="search" placeholder="項目名を検索（例：市民税、児童福祉費）" autocomplete="off"><div id="results"></div></div>
        <form id="page-jump" class="page-jump"><label for="page-number">原本ページ</label><input id="page-number" inputmode="numeric" pattern="[0-9０-９]+" placeholder="例：30"><button type="submit">移動</button><span id="page-status" class="status"></span></form>
      </section>
      <section class="panel">
        <nav id="breadcrumbs" aria-label="現在位置"></nav>
        <div id="charts"></div>
        <p id="source" class="source"></p>
      </section>
    </main>
    <script id="budget-data" type="application/json">#{embedded}</script>
    <script>
      const DATA=JSON.parse(document.getElementById('budget-data').textContent);
      const COLORS=['#2878b5','#ef8a47','#4ca66b','#d45d79','#8a68b8','#d4aa32','#40a6a6','#bd6d38','#7089a8','#9c7a62','#6aaf45','#c95fa4','#7672c7','#d07b95','#699d89','#a18b35','#4d93d0','#dc6951','#71944a','#9a73b5','#ba8743','#558fa0'];
      let account=DATA.accounts[0],kind='revenue',path=[],selected=null,restoring=false,businessView='list';
      const yen=new Intl.NumberFormat('ja-JP');
      const LEVEL={1:'款',2:'項',3:'目',4:'節'};
      const ACCOUNT_SLUG={general:'ippan','national-health':'kokuho','nursing-care':'kaigo','late-elderly':'koki'};
      const nodeLabel=n=>`${LEVEL[n.level]||''} ${n.code}　${n.name}`;
      const hierarchyKey=(a,nodes)=>`${ACCOUNT_SLUG[a.id]}-${nodes.filter(n=>n.level<=3).map(n=>n.code).join('-')}`;
      const jigyoKey=(a,nodes,item)=>`${ACCOUNT_SLUG[a.id]}-${nodes.filter(n=>n.level<=3).map(n=>n.code).join('-')}-${item.number}`;
      function setLocation(page,jigyo,replace=false){const u=new URL(location.href);page?u.searchParams.set('page',page):u.searchParams.delete('page');jigyo?u.searchParams.set('jigyo',jigyo):u.searchParams.delete('jigyo');history[replace?'replaceState':'pushState']({},'',u)}
      const $=id=>document.getElementById(id);
      const roots=()=>account[kind];
      const current=()=>path.length?path[path.length-1]:null;
      const children=()=>current()?current().children:roots();
      const total=()=>children().reduce((sum,n)=>sum+Math.max(0,n.amount),0);
      function polar(cx,cy,r,a){const q=(a-90)*Math.PI/180;return [cx+r*Math.cos(q),cy+r*Math.sin(q)]}
      function arc(a0,a1){if(a1-a0>359.999)return 'M300 55 A245 245 0 1 0 300 545 A245 245 0 1 0 300 55 Z';const [x0,y0]=polar(300,300,245,a1),[x1,y1]=polar(300,300,245,a0);return `M300 300 L${x0} ${y0} A245 245 0 ${a1-a0>180?1:0} 0 ${x1} ${y1} Z`}
      function addSliceLabel(svg,node,angle,fixed=false){const old=svg.querySelector(fixed?'.fixed-label':'.hover-label');old?.remove();const [x,y]=polar(300,300,175,angle),group=document.createElementNS('http://www.w3.org/2000/svg','text');group.setAttribute('x',x);group.setAttribute('y',y-16);group.setAttribute('class',`slice-label ${fixed?'fixed-label':'hover-label'}`);const chars=Array.from(node.name),lines=chars.length>18?[chars.slice(0,16).join('')+'…']:chars.length>9?[chars.slice(0,9).join(''),chars.slice(9).join('')]:[node.name];lines.forEach((line,i)=>{const t=document.createElementNS('http://www.w3.org/2000/svg','tspan');t.setAttribute('x',x);t.setAttribute('dy',i?22:0);t.textContent=line;group.append(t)});const amount=document.createElementNS('http://www.w3.org/2000/svg','tspan');amount.setAttribute('x',x);amount.setAttribute('dy',21);amount.setAttribute('class','amount');amount.textContent=`${yen.format(node.amount)}円`;group.append(amount);if(fixed){const note=document.createElementNS('http://www.w3.org/2000/svg','tspan');note.setAttribute('x',x);note.setAttribute('dy',20);note.setAttribute('class','detail-note');note.textContent='（詳細は以下）';group.append(note)}svg.append(group)}
      function businessModeControls(parent){const mode=document.createElement('div');mode.className='business-mode';mode.innerHTML=`<label><input type="checkbox" ${businessView==='chart'?'checked':''}>事業を円グラフ化</label>`;mode.querySelector('input').onchange=event=>{businessView=event.target.checked?'chart':'list';if(event.target.checked&&!parent.children.some(node=>node.id===selected)){const first=parent.children[0];selected=first?.id||null;if(first)setLocation(first.page,null)}render();if(selected)requestAnimationFrame(()=>document.querySelector('.business-breakdown')?.scrollIntoView({behavior:'smooth',block:'start'}))};return mode}
      function businessBreakdown(parent,section){const norm=s=>s.replace(/[\s　]/g,''),rows=parent.details.map(detail=>{const part=detail.sections?.find(item=>norm(item.name)===norm(section.name))||detail.sections?.find(item=>item.number===section.code);return part?{name:detail.name,number:detail.number,department:detail.department,amount:part.amount,items:part.items}:null}).filter(Boolean),wrap=document.createElement('div');wrap.className='business-breakdown';wrap.innerHTML=`<h3>${nodeLabel(section)}の事業内訳</h3>`;const total=rows.reduce((sum,row)=>sum+row.amount,0);if(total!==section.amount){const warning=document.createElement('p');warning.className='detail-check warn';warning.textContent=`注意：事業別合計が節額と${yen.format(Math.abs(total-section.amount))}円${total<section.amount?'不足':'超過'}しています。`;wrap.append(warning)}const content=document.createElement('div');wrap.append(content);if(businessView==='list'){const list=document.createElement('div');list.className='business-list';rows.forEach(row=>{const item=document.createElement('details'),summary=document.createElement('summary');summary.innerHTML=`事業 ${row.number}　${row.name}${row.department?` <span class="minor">（${row.department}）</span>`:''} <span class="detail-amount">${yen.format(row.amount)}円</span>`;item.append(summary);if(row.items?.length){const ul=document.createElement('ul');ul.className='item-list';row.items.forEach(entry=>{const li=document.createElement('li');li.innerHTML=`${entry.name} <span class="detail-amount">${yen.format(entry.amount)}円</span>`;ul.append(li)});item.append(ul)}list.append(item)});content.append(list);return wrap}const grid=document.createElement('div');grid.className='business-chart';const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 600 600');svg.setAttribute('class','chart');const legend=document.createElement('ul');legend.className='legend';grid.append(svg,legend);content.append(grid);let angle=0;rows.forEach((row,i)=>{const next=angle+row.amount/total*360,mid=(angle+next)/2,p=document.createElementNS('http://www.w3.org/2000/svg','path'),show=()=>{addSliceLabel(svg,row,mid);p.classList.add('hovered');svg.classList.add('has-hover')},hide=()=>{svg.querySelector('.hover-label')?.remove();p.classList.remove('hovered');svg.classList.remove('has-hover')};p.setAttribute('d',arc(angle,next));p.setAttribute('fill',COLORS[i%COLORS.length]);p.setAttribute('class','slice');p.onmouseenter=show;p.onmouseleave=hide;svg.append(p);const li=document.createElement('li'),button=document.createElement('button');button.innerHTML=`<span class="swatch" style="background:${COLORS[i%COLORS.length]}"></span><span>事業 ${row.number}　${row.name}</span><span class="money">${yen.format(row.amount)}円</span>`;button.onmouseenter=show;button.onmouseleave=hide;button.onfocus=show;button.onblur=hide;li.append(button);legend.append(li);angle=next});const hole=document.createElementNS('http://www.w3.org/2000/svg','circle');hole.setAttribute('cx',300);hole.setAttribute('cy',300);hole.setAttribute('r',105);hole.setAttribute('fill','white');svg.append(hole);const title=document.createElementNS('http://www.w3.org/2000/svg','text');title.setAttribute('x',300);title.setAttribute('y',300);title.setAttribute('text-anchor','middle');title.setAttribute('class','center-title');title.textContent=`節 ${section.code}`;svg.append(title);return wrap}
      function renderButtons(){
        $('accounts').innerHTML='';DATA.accounts.forEach(a=>{const b=document.createElement('button');b.textContent=a.name;b.className=a===account?'active':'';b.onclick=()=>{account=a;path=[];selected=null;setLocation(null,null);render()};$('accounts').append(b)});
        $('kinds').innerHTML='';[['revenue','歳入'],['expense','歳出']].forEach(([k,label])=>{const b=document.createElement('button');b.textContent=label;b.className=k===kind?'active':'';b.onclick=()=>{kind=k;path=[];selected=null;setLocation(null,null);render()};$('kinds').append(b)});
        const pages=Object.keys(account.pages[kind]).map(Number).sort((a,b)=>a-b);$('page-status').textContent=pages.length?`対応ページ：${pages[0]}〜${pages[pages.length-1]}（左右どちらでも可）`:'対応ページなし';
      }
      function renderCrumbs(){
        const nav=$('breadcrumbs');nav.innerHTML='';const base=document.createElement('button');base.textContent=`${account.name}・${kind==='revenue'?'歳入':'歳出'}`;base.onclick=()=>{path=[];selected=null;setLocation(null,null);render()};nav.append(base);
        path.forEach((node,i)=>{nav.append(document.createTextNode('›'));const b=document.createElement('button');b.textContent=nodeLabel(node);b.onclick=()=>{path=path.slice(0,i+1);selected=null;setLocation(node.page,hierarchyKey(account,path));render()};nav.append(b)});
      }
      function renderChart(nodes,parent,depth){
        const section=document.createElement('section');section.className='drill-panel';
        const heading=document.createElement('h2');heading.textContent=parent?`${nodeLabel(parent)}の内訳`:`${account.name}・${kind==='revenue'?'歳入':'歳出'}`;section.append(heading);
        const grid=document.createElement('div');grid.className='chart-grid';const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 600 600');svg.setAttribute('role','img');svg.setAttribute('class','chart');const list=document.createElement('ul');list.className='legend';grid.append(svg,list);section.append(grid);$('charts').append(section);
        const appendDetails=()=>{
          const chosenSection=parent?.level===3?parent.children.find(node=>node.id===selected):null;if(parent?.level===3)section.append(businessModeControls(parent));if(chosenSection){section.append(businessBreakdown(parent,chosenSection));return}
          if(!parent||(!parent.details.length&&!Number.isFinite(parent.detail_difference)))return;
          const details=document.createElement('div');details.className='details';details.innerHTML=`<h3>${kind==='expense'?'事業・節・個別支出':'決算書の備考'}</h3>`;
          if(kind==='expense'&&Number.isFinite(parent.detail_difference)&&parent.detail_difference!==0){const check=document.createElement('p'),diff=parent.detail_difference;check.className='detail-check warn';check.textContent=`注意：抽出した事業別合計は${yen.format(parent.detail_total)}円で、支出済額と${yen.format(Math.abs(diff))}円${diff<0?'不足':'超過'}しています。抽出漏れまたは誤読の可能性があります。`;details.append(check)}
          if(parent.details.length){const list=document.createElement('div');list.className='details-list';parent.details.forEach(item=>{const project=document.createElement('details');project.className='project-detail';project.dataset.number=item.number||'';project.dataset.key=jigyoKey(account,path.slice(0,depth),item);project.addEventListener('toggle',()=>{if(restoring)return;if(project.open)setLocation(item.page||parent.page,project.dataset.key);else if(new URL(location.href).searchParams.get('jigyo')===project.dataset.key)setLocation(item.page||parent.page,null)});const summary=document.createElement('summary');summary.innerHTML=`事業 ${item.number||'—'}　${item.name}${item.department?` <span class="minor">（${item.department}）</span>`:''} <span class="detail-amount">${yen.format(item.amount)}円</span>`;project.append(summary);if(Number.isFinite(item.section_difference)&&item.section_difference!==0){const check=document.createElement('p'),diff=item.section_difference;check.className='detail-check warn';check.textContent=`注意：節合計が事業額と${yen.format(Math.abs(diff))}円${diff<0?'不足':'超過'}しています。`;project.append(check)}if(item.sections?.length){const sections=document.createElement('ul');sections.className='section-list';item.sections.forEach(part=>{const li=document.createElement('li');li.innerHTML=`<strong>節 ${part.number}　${part.name}</strong> <span class="detail-amount">${yen.format(part.amount)}円</span>`;if(part.items?.length){const items=document.createElement('ul');items.className='item-list';part.items.forEach(entry=>{const row=document.createElement('li');row.innerHTML=`${entry.name} <span class="detail-amount">${yen.format(entry.amount)}円</span>`;items.append(row)});li.append(items)}if(Number.isFinite(part.item_difference)&&part.item_difference!==0){const warning=document.createElement('p');warning.className='detail-check warn';warning.textContent=`注意：個別支出合計が節額と${yen.format(Math.abs(part.item_difference))}円${part.item_difference<0?'不足':'超過'}しています。`;li.append(warning)}sections.append(li)});project.append(sections)}list.append(project)});details.append(list)}section.append(details)
        };
        nodes=nodes.filter(n=>n.amount>0);
        if(!nodes.length){svg.innerHTML='<text x="300" y="300" text-anchor="middle" class="empty">これより下の内訳はありません</text>';appendDetails();return section}
        const sum=nodes.reduce((s,n)=>s+n.amount,0),fixedNode=path[depth]||nodes.find(n=>n.id===selected),slices=[];let angle=0;
        nodes.forEach((node,i)=>{const next=angle+node.amount/sum*360,mid=(angle+next)/2,p=document.createElementNS('http://www.w3.org/2000/svg','path');p.setAttribute('d',arc(angle,next));p.setAttribute('fill',COLORS[i%COLORS.length]);p.setAttribute('class','slice'+(fixedNode===node?' selected':''));p.setAttribute('tabindex','0');p.setAttribute('aria-label',`${node.name} ${yen.format(node.amount)}円`);p.onclick=()=>openNode(node,depth);p.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();openNode(node,depth)}};const showHover=()=>{if(fixedNode!==node)addSliceLabel(svg,node,mid);p.classList.add('hovered');svg.classList.add('has-hover')},hideHover=()=>{svg.querySelector('.hover-label')?.remove();p.classList.remove('hovered');svg.classList.remove('has-hover')};p.onmouseenter=showHover;p.onmouseleave=hideHover;svg.append(p);slices.push([node,mid]);angle=next;
          const li=document.createElement('li'),b=document.createElement('button');b.innerHTML=`<span class="swatch" style="background:${COLORS[i%COLORS.length]}"></span><span>${nodeLabel(node)}<span class="minor"> ${node.children.length?'内訳あり':''}</span></span><span class="money">${yen.format(node.amount)}円<br><span class="minor">${(node.amount/sum*100).toFixed(1)}%</span></span>`;b.onclick=()=>openNode(node,depth);b.onmouseenter=showHover;b.onmouseleave=hideHover;b.onfocus=showHover;b.onblur=hideHover;li.append(b);list.append(li)});
        const hole=document.createElementNS('http://www.w3.org/2000/svg','circle');hole.setAttribute('cx',300);hole.setAttribute('cy',300);hole.setAttribute('r',105);hole.setAttribute('fill','white');svg.append(hole);
          const title=document.createElementNS('http://www.w3.org/2000/svg','text');title.setAttribute('x',300);title.setAttribute('y',292);title.setAttribute('text-anchor','middle');title.setAttribute('class','center-title');title.textContent=parent?nodeLabel(parent):(kind==='revenue'?'歳入':'歳出');svg.append(title);
        const value=document.createElementNS('http://www.w3.org/2000/svg','text');value.setAttribute('x',300);value.setAttribute('y',318);value.setAttribute('text-anchor','middle');value.setAttribute('class','center-value');value.textContent=yen.format(parent?parent.amount:sum)+'円';svg.append(value);if(fixedNode){const fixed=slices.find(([node])=>node===fixedNode);if(fixed)addSliceLabel(svg,fixed[0],fixed[1],true)}appendDetails();return section;
      }
      function renderCharts(){const box=$('charts');box.innerHTML='';renderChart(roots(),null,0);path.forEach((node,i)=>renderChart(node.children,node,i+1))}
      function openNode(node,depth){selected=node.id;const targetPath=[...path.slice(0,depth),node],key=node.level<=3?hierarchyKey(account,targetPath):null;if(node.children.length||node.details.length){path=targetPath;selected=null;setLocation(node.page,key);render(true)}else{setLocation(node.page,key);render();if(node.level===4)requestAnimationFrame(()=>document.querySelector('.business-breakdown')?.scrollIntoView({behavior:'smooth',block:'start'}))} }
      function flatten(){const out=[];DATA.accounts.forEach(a=>['revenue','expense'].forEach(k=>{const walk=(nodes,trail)=>nodes.forEach(n=>{out.push({a,k,n,trail});n.details.forEach(detail=>{out.push({a,k,n,trail,detail});detail.sections?.forEach(part=>{out.push({a,k,n,trail,detail,sub:part});part.items?.forEach(sub=>out.push({a,k,n,trail,detail,sub}))})});walk(n.children,[...trail,n])});walk(a[k],[])}));return out}
      const SEARCH=flatten();
      SEARCH.forEach(x=>{if(x.detail&&x.k==='expense')x.jigyo=jigyoKey(x.a,[...x.trail,x.n],x.detail);else if(!x.detail&&x.k==='expense'&&x.n.level<=3)x.jigyo=hierarchyKey(x.a,[...x.trail,x.n])});
      function pageHit(page,preferCurrent=true){const candidates=[];DATA.accounts.forEach(a=>['revenue','expense'].forEach(k=>{const id=a.pages[k][page];if(id){const hit=SEARCH.find(x=>!x.detail&&x.a===a&&x.k===k&&x.n.id===id);if(hit)candidates.push(hit)}}));return (preferCurrent&&candidates.find(x=>x.a===account&&x.k===kind))||candidates[0]}
      function firstProject(hit,page){if(!hit)return null;const id=hit.a.pages[hit.k][page],paired=Object.keys(hit.a.pages[hit.k]).filter(p=>hit.a.pages[hit.k][p]===id).map(Number),descendants=SEARCH.filter(x=>x.detail&&x.a===hit.a&&x.k===hit.k&&[...x.trail,x.n].some(n=>n.id===hit.n.id));return descendants.find(x=>paired.includes(x.detail.page))||descendants[0]}
      function showHit(hit,scroll=true){account=hit.a;kind=hit.k;path=(hit.n.children.length||hit.n.details.length)?[...hit.trail,hit.n]:hit.trail;selected=path.includes(hit.n)?null:hit.n.id;render(scroll)}
      function openProject(hit,scroll=true){restoring=true;showHit(hit,false);requestAnimationFrame(()=>{const project=document.querySelector(`.project-detail[data-key="${CSS.escape(hit.jigyo)}"]`);if(project){project.open=true;if(scroll)project.scrollIntoView({behavior:'smooth',block:'start'})}setTimeout(()=>restoring=false,0)})}
      function jumpToPage(event){event.preventDefault();const raw=$('page-number').value.replace(/[０-９]/g,c=>String.fromCharCode(c.charCodeAt(0)-65248)),page=raw.match(/[0-9]+/)?.[0],hit=page&&pageHit(page);if(!hit){$('page-status').textContent='該当ページがありません';return}const project=firstProject(hit,page);setLocation(page,project?.jigyo);project?openProject(project):showHit(hit);$('page-status').textContent=`原本${page}ページ付近：${hit.n.name}`}
      function renderSearch(){const q=$('search').value.replace(/[\s　]/g,'').toLowerCase(),box=$('results');box.innerHTML='';if(!q){box.style.display='none';return}const found=SEARCH.filter(x=>(x.sub?.name||x.detail?.name||x.n.name).replace(/[\s　]/g,'').toLowerCase().includes(q)).slice(0,40);found.forEach(x=>{const label=x.sub?.name||x.detail?.name||x.n.name,b=document.createElement('button');b.innerHTML=`${label}<span class="result-path">${x.a.name} › ${x.k==='revenue'?'歳入':'歳出'} › ${[...x.trail,x.n].map(nodeLabel).join(' › ')}</span>`;b.onclick=()=>{$('search').value=label;box.style.display='none';if(x.detail){setLocation(x.detail.page||x.n.page,x.jigyo);openProject(x)}else{setLocation(x.n.page,x.jigyo);showHit(x)}};box.append(b)});box.style.display=found.length?'block':'none'}
      function applyUrl(){const params=new URL(location.href).searchParams,page=params.get('page'),key=params.get('jigyo'),jhit=key&&SEARCH.find(x=>x.jigyo===key);if(jhit){const resolvedPage=jhit.detail?.page||jhit.n.page;setLocation(resolvedPage,jhit.jigyo,true);jhit.detail?openProject(jhit,false):showHit(jhit,false);$('page-number').value=resolvedPage||'';return}if(page){const hit=pageHit(page);if(!hit){render();$('page-status').textContent=`原本${page}ページは見つかりません`;return}const project=firstProject(hit,page);setLocation(page,project?.jigyo,true);project?openProject(project,false):showHit(hit,false);$('page-number').value=page;return}render()}
      function render(scroll=false){renderButtons();renderCrumbs();renderCharts();const src=account.sources[kind];$('source').innerHTML=`出典：<a href="${encodeURI(src)}">${src}</a>（支出済額／収入済額）`;if(scroll)requestAnimationFrame(()=>document.querySelector('.drill-panel:last-child')?.scrollIntoView({behavior:'smooth',block:'start'}))}
      $('search').addEventListener('input',renderSearch);$('page-jump').addEventListener('submit',jumpToPage);document.addEventListener('click',e=>{if(!e.target.closest('.search-wrap'))$('results').style.display='none'});addEventListener('popstate',applyUrl);applyUrl();
    </script>
  </body>
  </html>
HTML
File.write(File.join(ROOT, "index.html"), html)
warn "generated #{accounts.length} accounts, #{node_count} nodes, #{detail_count} details; all hierarchy totals match"
