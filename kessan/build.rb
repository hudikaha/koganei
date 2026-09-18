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

  extract_text(pdf).each_line do |line|
    if (parts = row_parts(line, kind))
      level = parts[0]
      if (node = queues[level].shift)
        stack = stack.take(level - 1)
        stack[level - 1] = node
      end
    end

    right = line[(kind == :revenue ? 180 : 184)..].to_s.strip
    next if right.empty?
    next if right.match?(/\A(?:備考|説\s*明|円|款|項|目|節|[-－]\d+[-－])\z/)

    if (match = right.match(/\A(.+?)\s+[（(]?\s*((?:△|-)?\d[\d,]*)\s*[）)]?\s*\z/))
      text = [buffer, match[1]].compact.join
      buffer = nil
      text = text.gsub(/[[:space:]　]+/, " ").strip
      text = text.sub(/\A(?:[,\d]+\s+)+/, "")
      next if text.empty? || text.match?(/\A[\d.]+\z/)
      target = kind == :revenue ? (stack[3] || stack[2]) : stack[2]
      next unless target
      amount = amount_values(match[2]).first
      detail = { "name" => text, "amount" => amount }
      target["details"] << detail unless target["details"].any? { |item| item == detail }
    elsif kind == :expense && (buffer || right.match?(/\A(?:\(?\s*\d+\)?|（\s*\d+\s*）)\s*\S/))
      buffer = [buffer, right].compact.join
    else
      buffer = nil
    end
  end
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
    page.each_line do |line|
      next unless (parts = row_parts(line, kind))
      level, = parts
      continued = parts[5]
      node = queues[level].shift
      next unless node
      first_any ||= node
      first_new ||= node if level <= 3 && !continued
    end
    target = first_new || first_any
    next unless target
    page.scan(/[-－]\s*(\d+)\s*[-－]/).flatten.map(&:to_i).uniq.each do |printed_page|
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
      .chart{width:100%;height:auto;max-height:650px}.slice{cursor:pointer;stroke:white;stroke-width:2}.slice.selected{stroke:#17212b;stroke-width:5}
      .center-title{font-weight:700;font-size:15px}.center-value{font-size:13px;fill:#52606a}
      .legend{list-style:none;padding:0;margin:0;max-height:620px;overflow:auto}.legend button{display:grid;grid-template-columns:1rem 1fr auto;gap:.5rem;width:100%;border:0;border-radius:7px;text-align:left;align-items:center;padding:.5rem}
      .legend button:hover,.legend button:focus{background:#edf5f8}.swatch{width:.8rem;height:.8rem;border-radius:2px}.money{font-variant-numeric:tabular-nums;white-space:nowrap}.minor{color:#68757e;font-size:.85rem}
      .details{margin-top:1rem;border-top:1px solid #d7dde2;padding-top:.8rem}.details h3{font-size:1rem;margin:.2rem 0 .6rem}.details ul{columns:2;column-gap:2rem;margin:0;padding-left:1.3rem}.details li{break-inside:avoid;margin:.25rem 0}.detail-amount{white-space:nowrap;color:#52606a}
      .empty{text-align:center;padding:4rem 1rem;color:#68757e}.source{margin-top:1rem;font-size:.9rem}a{color:#15607e}
      @media(max-width:760px){.chart-grid{grid-template-columns:1fr}.legend{max-height:none}.details ul{columns:1}}
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
      let account=DATA.accounts[0],kind='revenue',path=[],selected=null;
      const yen=new Intl.NumberFormat('ja-JP');
      const $=id=>document.getElementById(id);
      const roots=()=>account[kind];
      const current=()=>path.length?path[path.length-1]:null;
      const children=()=>current()?current().children:roots();
      const total=()=>children().reduce((sum,n)=>sum+Math.max(0,n.amount),0);
      function polar(cx,cy,r,a){const q=(a-90)*Math.PI/180;return [cx+r*Math.cos(q),cy+r*Math.sin(q)]}
      function arc(a0,a1){if(a1-a0>359.999)return 'M300 55 A245 245 0 1 0 300 545 A245 245 0 1 0 300 55 Z';const [x0,y0]=polar(300,300,245,a1),[x1,y1]=polar(300,300,245,a0);return `M300 300 L${x0} ${y0} A245 245 0 ${a1-a0>180?1:0} 0 ${x1} ${y1} Z`}
      function renderButtons(){
        $('accounts').innerHTML='';DATA.accounts.forEach(a=>{const b=document.createElement('button');b.textContent=a.name;b.className=a===account?'active':'';b.onclick=()=>{account=a;path=[];selected=null;render()};$('accounts').append(b)});
        $('kinds').innerHTML='';[['revenue','歳入'],['expense','歳出']].forEach(([k,label])=>{const b=document.createElement('button');b.textContent=label;b.className=k===kind?'active':'';b.onclick=()=>{kind=k;path=[];selected=null;render()};$('kinds').append(b)});
        const pages=Object.keys(account.pages[kind]).map(Number).sort((a,b)=>a-b);$('page-status').textContent=pages.length?`対応ページ：${pages[0]}〜${pages[pages.length-1]}（左右どちらでも可）`:'対応ページなし';
      }
      function renderCrumbs(){
        const nav=$('breadcrumbs');nav.innerHTML='';const base=document.createElement('button');base.textContent=`${account.name}・${kind==='revenue'?'歳入':'歳出'}`;base.onclick=()=>{path=[];selected=null;render()};nav.append(base);
        path.forEach((node,i)=>{nav.append(document.createTextNode('›'));const b=document.createElement('button');b.textContent=node.name;b.onclick=()=>{path=path.slice(0,i+1);selected=null;render()};nav.append(b)});
      }
      function renderChart(nodes,parent,depth){
        const section=document.createElement('section');section.className='drill-panel';
        const heading=document.createElement('h2');heading.textContent=parent?`${parent.name}の内訳`:`${account.name}・${kind==='revenue'?'歳入':'歳出'}`;section.append(heading);
        const grid=document.createElement('div');grid.className='chart-grid';const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 600 600');svg.setAttribute('role','img');svg.setAttribute('class','chart');const list=document.createElement('ul');list.className='legend';grid.append(svg,list);section.append(grid);$('charts').append(section);
        const appendDetails=()=>{if(!parent||!parent.details.length)return;const details=document.createElement('div');details.className='details';details.innerHTML='<h3>決算書の説明</h3>';const ul=document.createElement('ul');parent.details.forEach(item=>{const li=document.createElement('li');li.innerHTML=`${item.name} <span class="detail-amount">${yen.format(item.amount)}円</span>`;ul.append(li)});details.append(ul);section.append(details)};
        nodes=nodes.filter(n=>n.amount>0);
        if(!nodes.length){svg.innerHTML='<text x="300" y="300" text-anchor="middle" class="empty">これより下の内訳はありません</text>';appendDetails();return section}
        const sum=nodes.reduce((s,n)=>s+n.amount,0);let angle=0;
        nodes.forEach((node,i)=>{const next=angle+node.amount/sum*360;const p=document.createElementNS('http://www.w3.org/2000/svg','path');p.setAttribute('d',arc(angle,next));p.setAttribute('fill',COLORS[i%COLORS.length]);p.setAttribute('class','slice'+(selected===node.id?' selected':''));p.setAttribute('tabindex','0');p.setAttribute('aria-label',`${node.name} ${yen.format(node.amount)}円`);p.onclick=()=>openNode(node,depth);p.onkeydown=e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();openNode(node,depth)}};svg.append(p);angle=next;
          const li=document.createElement('li'),b=document.createElement('button');b.innerHTML=`<span class="swatch" style="background:${COLORS[i%COLORS.length]}"></span><span>${node.name}<span class="minor"> ${node.children.length?'内訳あり':''}</span></span><span class="money">${yen.format(node.amount)}円<br><span class="minor">${(node.amount/sum*100).toFixed(1)}%</span></span>`;b.onclick=()=>openNode(node,depth);li.append(b);list.append(li)});
        const hole=document.createElementNS('http://www.w3.org/2000/svg','circle');hole.setAttribute('cx',300);hole.setAttribute('cy',300);hole.setAttribute('r',105);hole.setAttribute('fill','white');svg.append(hole);
        const title=document.createElementNS('http://www.w3.org/2000/svg','text');title.setAttribute('x',300);title.setAttribute('y',292);title.setAttribute('text-anchor','middle');title.setAttribute('class','center-title');title.textContent=parent?parent.name:(kind==='revenue'?'歳入':'歳出');svg.append(title);
        const value=document.createElementNS('http://www.w3.org/2000/svg','text');value.setAttribute('x',300);value.setAttribute('y',318);value.setAttribute('text-anchor','middle');value.setAttribute('class','center-value');value.textContent=yen.format(parent?parent.amount:sum)+'円';svg.append(value);appendDetails();return section;
      }
      function renderCharts(){const box=$('charts');box.innerHTML='';renderChart(roots(),null,0);path.forEach((node,i)=>renderChart(node.children,node,i+1))}
      function openNode(node,depth){selected=node.id;if(node.children.length||node.details.length){path=path.slice(0,depth);path.push(node);selected=null;render(true)}else{render()} }
      function flatten(){const out=[];DATA.accounts.forEach(a=>['revenue','expense'].forEach(k=>{const walk=(nodes,trail)=>nodes.forEach(n=>{out.push({a,k,n,trail});n.details.forEach(detail=>out.push({a,k,n,trail,detail}));walk(n.children,[...trail,n])});walk(a[k],[])}));return out}
      const SEARCH=flatten();
      function jumpToPage(event){event.preventDefault();const raw=$('page-number').value.replace(/[０-９]/g,c=>String.fromCharCode(c.charCodeAt(0)-65248)),page=raw.match(/[0-9]+/)?.[0],id=page&&account.pages[kind][page];if(!id){$('page-status').textContent='この会計・歳入歳出には該当ページがありません';return}const hit=SEARCH.find(x=>!x.detail&&x.a===account&&x.k===kind&&x.n.id===id);if(!hit)return;path=(hit.n.children.length||hit.n.details.length)?[...hit.trail,hit.n]:hit.trail;selected=path.includes(hit.n)?null:hit.n.id;render(true);$('page-status').textContent=`原本${page}ページ付近：${hit.n.name}`}
      function renderSearch(){const q=$('search').value.replace(/[\s　]/g,'').toLowerCase(),box=$('results');box.innerHTML='';if(!q){box.style.display='none';return}const found=SEARCH.filter(x=>(x.detail?.name||x.n.name).replace(/[\s　]/g,'').toLowerCase().includes(q)).slice(0,40);found.forEach(x=>{const label=x.detail?.name||x.n.name,b=document.createElement('button');b.innerHTML=`${label}<span class="result-path">${x.a.name} › ${x.k==='revenue'?'歳入':'歳出'} › ${[...x.trail,x.n].map(n=>n.name).join(' › ')}</span>`;b.onclick=()=>{account=x.a;kind=x.k;path=(x.detail||x.n.children.length||x.n.details.length)?[...x.trail,x.n]:x.trail;selected=path.includes(x.n)?null:x.n.id;$('search').value=label;box.style.display='none';render(true)};box.append(b)});box.style.display=found.length?'block':'none'}
      function render(scroll=false){renderButtons();renderCrumbs();renderCharts();const src=account.sources[kind];$('source').innerHTML=`出典：<a href="${encodeURI(src)}">${src}</a>（支出済額／収入済額）`;if(scroll)requestAnimationFrame(()=>document.querySelector('.drill-panel:last-child')?.scrollIntoView({behavior:'smooth',block:'start'}))}
      $('search').addEventListener('input',renderSearch);$('page-jump').addEventListener('submit',jumpToPage);document.addEventListener('click',e=>{if(!e.target.closest('.search-wrap'))$('results').style.display='none'});render();
    </script>
  </body>
  </html>
HTML
File.write(File.join(ROOT, "index.html"), html)
warn "generated #{accounts.length} accounts, #{node_count} nodes, #{detail_count} details; all hierarchy totals match"
