// Usage report runtime, modelled on the Usage page of T3 Code (MIT, T3 Tools Inc.).
// Reads the embedded REPORT snapshot and renders every section without network access.
(() => {
  const COPY = {
    en: {
      usage:'Usage',localHistory:'Local history',cost:'Cost',tokens:'Tokens',totals:'Totals',breakdown:'Breakdown',model:'Model',day:'Day',
      periodName:n=>`${n} ${n===1?'day':'days'}`,range:(a,b)=>`${a} to ${b}`,
      daysRecorded:n=>`${n} ${n===1?'day':'days'} recorded`,apiEstimate:'API estimate',
      unpricedInfo:p=>`API estimate excludes ${p} of tokens, which are unpriced.`,
      ofCost:p=>`${p} of cost`,ofTokens:p=>`${p} of tokens`,tokenCount:v=>`${v} tokens`,
      dailyCost:'Daily cost',dailyTokens:'Daily processed tokens',
      processedTokens:'Processed tokens',cachedInput:'Cached input',uncachedInput:'Uncached input',output:'Output',cacheSavings:'Cache savings',
      costByType:'Cost by type',tokensByType:'Tokens by type',costBySpeed:'Cost by speed',
      input:'Input',cacheRead:'Cache read',cacheWrite:'Cache write',standard:'Standard',fast:'Fast',premium:'Premium',
      share:'Share',total:'Total',noActivity:'No activity in this window.',unpriced:'Unpriced',noRecord:'No record',
      metric:'Usage metric',language:'Language',breakdownGroup:'Usage breakdown',
      last7:'7 days',last30:'30 days',custom:'Custom',period:'Usage period',rangeFrom:'Start date',rangeTo:'End date',
    },
    zh: {
      usage:'用量',localHistory:'本地记录',cost:'费用',tokens:'Tokens',totals:'合计',breakdown:'明细',model:'模型',day:'日期',
      periodName:n=>`${n} 天`,range:(a,b)=>`${a} 至 ${b}`,
      daysRecorded:n=>`${n} 天有记录`,apiEstimate:'API 估算',
      unpricedInfo:p=>`API 估算未计入 ${p} 的未定价 tokens。`,
      ofCost:p=>`占费用 ${p}`,ofTokens:p=>`占 tokens ${p}`,tokenCount:v=>`${v} tokens`,
      dailyCost:'每日费用',dailyTokens:'每日处理 tokens',
      processedTokens:'处理 tokens',cachedInput:'缓存输入',uncachedInput:'未缓存输入',output:'输出',cacheSavings:'缓存节省',
      costByType:'按类型的费用',tokensByType:'按类型的 tokens',costBySpeed:'按速度的费用',
      input:'输入',cacheRead:'缓存读取',cacheWrite:'缓存写入',standard:'标准',fast:'Fast',premium:'溢价',
      share:'占比',total:'合计',noActivity:'此区间没有用量。',unpriced:'未定价',noRecord:'无记录',
      metric:'用量指标',language:'语言',breakdownGroup:'用量明细',
      last7:'7 天',last30:'30 天',custom:'自定义',period:'统计区间',rangeFrom:'开始日期',rangeTo:'结束日期',
    },
  };

  const ICONS = {
    openai:{viewBox:'100 100 411 411',paths:[{d:'M252.794 108.802C289.191 99.0484 326.265 110.305 351.148 135.135C385.113 126.072 422.85 134.862 449.492 161.505C476.136 188.149 484.925 225.888 475.862 259.85V259.854C500.696 284.735 511.95 321.81 502.198 358.207C492.447 394.602 464.161 421.084 430.215 430.217C421.083 464.162 394.603 492.448 358.206 502.199C321.812 511.951 284.734 500.693 259.852 475.864C225.887 484.927 188.15 476.137 161.507 449.495C134.864 422.851 126.073 385.111 135.136 351.149C110.304 326.266 99.0496 289.192 108.801 252.795C118.552 216.4 146.84 189.918 180.784 180.785C189.917 146.841 216.396 118.553 252.794 108.802ZM374.292 407.145C374.292 411.271 372.092 415.086 368.517 417.148L283.723 466.102C302.487 480.585 327.555 486.459 352.217 479.852C386.997 470.532 410.068 439.312 410.555 405.006V317.717C410.555 315.08 409.125 312.621 406.843 311.303L374.292 292.509V407.145ZM251.868 415.897C248.296 417.959 243.893 417.959 240.317 415.897L155.526 366.942C152.366 390.436 159.811 415.08 177.866 433.136H177.863C203.325 458.594 241.896 462.962 271.85 446.232L347.449 402.586C349.735 401.268 351.148 398.8 351.148 396.163V358.579L251.868 415.897ZM368.602 220.628C366.319 219.309 363.474 219.318 361.191 220.637L328.641 239.431L427.921 296.749C431.496 298.811 433.697 302.627 433.697 306.752V404.661C455.622 395.654 473.244 376.881 479.851 352.218C489.169 317.442 473.668 281.85 444.201 264.274L368.602 220.628ZM177.303 206.34C155.377 215.348 137.756 234.122 131.148 258.783C121.832 293.561 137.331 329.153 166.799 346.727L242.398 390.373C244.68 391.692 247.525 391.684 249.807 390.366L282.357 371.572L183.078 314.253C179.504 312.189 177.303 308.375 177.303 304.251V206.34ZM259.849 279.145V331.858L305.5 358.213L351.15 331.858V279.145L305.5 252.789L259.849 279.145ZM327.276 144.9C308.512 130.418 283.445 124.543 258.782 131.15C224.002 140.471 200.931 171.691 200.445 205.995V293.286C200.445 295.923 201.875 298.381 204.158 299.7L236.707 318.493V203.856C236.707 199.731 238.909 195.916 242.483 193.853L327.276 144.9ZM433.137 177.867C407.675 152.407 369.103 148.038 339.149 164.769L263.55 208.415C261.265 209.734 259.852 212.202 259.852 214.838V252.423L359.132 195.105C362.703 193.041 367.108 193.041 370.682 195.105L455.473 244.06C458.635 220.567 451.189 195.922 433.135 177.867H433.137Z',fill:'var(--mark-codex)',rule:'evenodd'}]},
    claude:{viewBox:'0 0 256 257',paths:[{d:'m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z',fill:'#d97757'}]},
    opencode:{viewBox:'0 0 32 40',paths:[{d:'M24 32H8V16H24V32Z',fill:'var(--mark-opencode-inner)'},{d:'M24 8H8V32H24V8ZM32 40H0V0H32V40Z',fill:'var(--mark-opencode)'}]},
    pi:{viewBox:'165.29 165.29 469.43 469.43',paths:[{d:'M165.29 165.29H517.36V400H400V517.36H282.65V634.72H165.29ZM282.65 282.65V400H400V282.65Z',fill:'var(--mark-pi)',rule:'evenodd'},{d:'M517.36 400H634.72V634.72H517.36Z',fill:'var(--mark-pi)'}]},
  };
  const PROVIDERS = {
    codex:{label:'Codex',color:'var(--foreground)',icon:'openai'},
    claude:{label:'Claude Code',color:'#d97757',icon:'claude'},
    openCode:{label:'OpenCode',color:'#5b9bbd',icon:'opencode'},
    piAgent:{label:'Pi Agent',color:'#4d9f8a',icon:'pi'},
  };
  const ORDER = Object.keys(PROVIDERS);
  const NAME_TO_ID = {Codex:'codex',Claude:'claude','Claude Code':'claude',OpenCode:'openCode','Pi Agent':'piAgent',Pi:'piAgent'};
  const sourceId = row => row.source ?? NAME_TO_ID[row.name] ?? row.name;
  const presentation = id => PROVIDERS[id] ?? {label:id,color:'#8b8b8b',icon:null};

  const ink = p => `color-mix(in oklab, var(--foreground) ${p}%, var(--background))`;
  const TYPE_COLORS = {input:ink(60),cacheRead:ink(30),cacheWrite:ink(72),output:ink(100)};

  const CURRENCY = new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',minimumFractionDigits:2,maximumFractionDigits:2});
  const INTEGER = new Intl.NumberFormat('en-US');
  const usd = v => CURRENCY.format(v);
  const count = v => INTEGER.format(Math.round(v));
  const trim = v => { const a=Math.abs(v); return v.toFixed(a>=100?0:a>=10?1:2).replace(/\.0+$/,''); };
  const tokens = v => {
    const a=Math.abs(v);
    if(a>=1e12)return trim(v/1e12)+'T';
    if(a>=1e9)return trim(v/1e9)+'B';
    if(a>=1e6)return trim(v/1e6)+'M';
    if(a>=1e3)return trim(v/1e3)+'K';
    return count(v);
  };
  const percent = (share,digits=1) => {
    const p=share*100,smallest=10**-digits;
    return p>0&&p<smallest?`<${smallest.toFixed(digits)}%`:`${p.toFixed(digits)}%`;
  };
  const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];

  let language='zh',metric='cost',breakdown='model',period='30',range={from:'',to:''};
  const t = key => COPY[language][key] ?? COPY.en[key] ?? key;
  const dayShort = day => {
    const [,m,d]=day.split('-').map(Number);
    if(!m||!d)return day;
    return language==='zh'?`${m}月${d}日`:`${MONTHS[m-1]} ${d}`;
  };

  // Saved history, one entry per calendar day. Every figure on the page is summed from the days
  // inside the selected period, so changing the period needs no new snapshot.
  const FIELDS=['input','output','cacheRead','cacheWrite','cacheWrite1h','cost','unpricedTokens','total'];
  const COST_FIELDS=['input','output','cacheRead','cacheWrite','cacheSavings','fast','fastPremium'];
  // The app's live view replaces the snapshot in place, so everything read from it is reassignable.
  let report,BY_DAY,FIRST_DAY,LAST_DAY,DEFAULT_PERIOD;
  function load(next){
    report=next;
    const history=report.history??report.days;
    BY_DAY=new Map(history.map(d=>[d.day,d]));
    FIRST_DAY=history[0]?.day??'';LAST_DAY=history.at(-1)?.day??'';
    DEFAULT_PERIOD=String(report.days.length)==='7'?'7':'30';
  }
  load(REPORT);
  const toTime=day=>Date.parse(day+'T00:00:00Z');
  const fromTime=time=>new Date(time).toISOString().slice(0,10);
  const shiftDay=(day,offset)=>fromTime(toTime(day)+offset*86400000);
  const zero=keys=>Object.fromEntries(keys.map(k=>[k,0]));
  const addInto=(target,row,keys)=>{for(const k of keys)target[k]+=row?.[k]??0;return target;};
  function periodRange(){
    if(period==='custom'&&range.from&&range.to)return range.from<=range.to?range:{from:range.to,to:range.from};
    return {from:shiftDay(LAST_DAY,1-Number(period==='7'?7:30)),to:LAST_DAY};
  }

  let days=[],daySources=[],totals,breakdownCost,recordedDays=0,sourceRows=new Map(),providers=[],models=[];
  function derive(){
    const {from,to}=periodRange();
    days=[];
    for(let time=toTime(from);time<=toTime(to);time+=86400000){
      const key=fromTime(time);
      days.push(BY_DAY.get(key)??{day:key,recorded:false,...zero(FIELDS),sources:[],models:[]});
    }
    daySources=days.map(day=>new Map((day.sources??[]).map(row=>[sourceId(row),row])));
    if(report.sources.length===1)days.forEach((day,i)=>{if(day.recorded&&!daySources[i].size)daySources[i].set(sourceId(report.sources[0]),day);});
    totals=days.reduce((sum,day)=>addInto(sum,day,FIELDS),zero(FIELDS));
    breakdownCost=days.reduce((sum,day)=>addInto(sum,day.costBreakdown,COST_FIELDS),zero(COST_FIELDS));
    recordedDays=days.filter(d=>d.recorded).length;
    sourceRows=new Map();
    daySources.forEach(m=>m.forEach((row,id)=>{if(!sourceRows.has(id))sourceRows.set(id,{name:row.name,source:id,...zero(FIELDS)});addInto(sourceRows.get(id),row,FIELDS);}));
    providers=[...sourceRows.keys()].filter(id=>{const r=sourceRows.get(id);return r.total>0||r.cost>0;})
      .sort((a,b)=>(ORDER.indexOf(a)+1||99)-(ORDER.indexOf(b)+1||99));
    // A model used through several sources is one row, marked with the source that used most tokens.
    const byModel=new Map();
    for(const day of days)for(const row of day.models??[]){
      if(!byModel.has(row.name))byModel.set(row.name,{name:row.name,...zero(FIELDS),bySource:new Map()});
      const entry=addInto(byModel.get(row.name),row,FIELDS),id=sourceId(row);
      entry.bySource.set(id,(entry.bySource.get(id)??0)+row.total);
    }
    models=[...byModel.values()].map(m=>({...m,source:[...m.bySource].sort((a,b)=>b[1]-a[1])[0]?.[0]}));
  }
  const providerDays = id => daySources.filter((m,i)=>days[i].recorded&&m.has(id)).length;
  const unknownCost = row => row.total>0&&row.unpricedTokens>=row.total;
  const value = row => metric==='tokens'?(row?.total??0):(row?.cost??0);
  const format = v => metric==='tokens'?tokens(v):usd(v);

  // DOM helpers. Text always goes through textContent, so model names never become markup.
  const NS='http://www.w3.org/2000/svg';
  function h(tag,attrs={},...children){
    const node=document.createElement(tag);
    for(const [k,v] of Object.entries(attrs)){
      if(v==null||v===false)continue;
      if(k==='class')node.className=v;else if(k==='style')node.style.cssText=v;else node.setAttribute(k,v===true?'':v);
    }
    for(const child of children.flat()){if(child==null||child===false)continue;node.append(child instanceof Node?child:document.createTextNode(String(child)));}
    return node;
  }
  function s(tag,attrs={}){const node=document.createElementNS(NS,tag);for(const [k,v] of Object.entries(attrs))if(v!=null)node.setAttribute(k,v);return node;}
  function mark(id,size){
    const icon=ICONS[presentation(id).icon];
    const box=h('span',{class:'mark','aria-hidden':'true',style:`width:${size}px;height:${size}px`});
    if(!icon){box.append(h('span',{class:'dot',style:`background:${presentation(id).color};width:${size}px;height:${size}px`}));return box;}
    const svg=s('svg',{viewBox:icon.viewBox,preserveAspectRatio:'xMidYMid'});
    icon.paths.forEach(p=>svg.append(s('path',{d:p.d,fill:p.fill,'fill-rule':p.rule,'clip-rule':p.rule})));
    box.append(svg);return box;
  }
  const infoIcon=()=>{const svg=s('svg',{viewBox:'0 0 24 24',fill:'none',stroke:'currentColor','stroke-width':2,'stroke-linecap':'round','stroke-linejoin':'round'});
    svg.append(s('circle',{cx:12,cy:12,r:10}),s('path',{d:'M12 16v-4'}),s('path',{d:'M12 8h.01'}));return svg;};

  function summary(){
    const root=document.getElementById('summary');root.replaceChildren();
    const hero=metric==='cost'?(unknownCost(totals)?t('unpriced'):usd(totals.cost)):tokens(totals.total);
    const meta=h('span',{class:'hero-meta'},h('span',{},t('daysRecorded')(recordedDays),metric==='cost'?' · '+t('apiEstimate'):''));
    if(metric==='cost'&&totals.unpricedTokens>0&&totals.total>0){
      meta.append(h('span',{class:'info',tabindex:0,'data-tip':t('unpricedInfo')(percent(totals.unpricedTokens/totals.total)),'aria-label':t('unpricedInfo')(percent(totals.unpricedTokens/totals.total))},infoIcon()));
    }
    root.append(h('div',{class:'hero'},h('span',{class:'hero-value',title:metric==='cost'?usd(totals.cost):count(totals.total)+' tokens'},hero),meta));
    for(const id of providers){
      const row=sourceRows.get(id),p=presentation(id),n=providerDays(id);
      const share=metric==='cost'?(totals.cost>0?row.cost/totals.cost:0):(totals.total>0?row.total/totals.total:0);
      root.append(h('div',{class:'provider'},
        h('div',{class:'provider-line'},
          h('span',{class:'provider-name'},h('span',{class:'dot',style:`background:${p.color}`,'aria-hidden':'true'}),mark(id,16),
            h('span',{class:'provider-label'},h('span',{class:'label'},p.label),h('span',{class:'count'},t('daysRecorded')(n)))),
          h('span',{class:'provider-value'},metric==='cost'&&unknownCost(row)?t('unpriced'):format(value(row)))),
        h('span',{class:'provider-sub'},metric==='cost'
          ?`${t('ofCost')(percent(share))} · ${t('tokenCount')(tokens(row.total))}`
          :`${t('ofTokens')(percent(share))} · ${unknownCost(row)?t('unpriced'):usd(row.cost)}`)));
    }
  }

  // Line chart: one monotone curve per source, sharing a zero-based scale.
  const VIEW_W=960,VIEW_H=260,PLOT_TOP=8,TICKS=4;
  function niceScale(peak){
    if(peak<=0)return {max:0,ticks:[0]};
    const raw=peak/TICKS,mag=10**Math.floor(Math.log10(raw)),norm=raw/mag;
    const step=(norm>5?10:norm>2?5:norm>1?2:1)*mag,max=Math.ceil(peak/step)*step,ticks=[];
    for(let v=0;v<=max+step*1e-6;v+=step)ticks.push(v);
    return {max,ticks};
  }
  function tangents(pts){
    const n=pts.length;if(n<2)return [0];
    const slopes=[];for(let i=0;i<n-1;i++){const dx=pts[i+1].x-pts[i].x;slopes.push(dx===0?0:(pts[i+1].y-pts[i].y)/dx);}
    const m=Array(n).fill(0);m[0]=slopes[0];m[n-1]=slopes[n-2];
    for(let i=1;i<n-1;i++){const a=slopes[i-1],b=slopes[i];m[i]=a*b<=0?0:(a+b)/2;}
    for(let i=0;i<n-1;i++){
      const sl=slopes[i];if(sl===0){m[i]=0;m[i+1]=0;continue;}
      const a=m[i]/sl,b=m[i+1]/sl,mag=a*a+b*b;
      if(mag>9){const k=3/Math.sqrt(mag);m[i]=k*a*sl;m[i+1]=k*b*sl;}
    }
    return m;
  }
  function curve(pts){
    if(pts.length<2)return '';
    const m=tangents(pts),f=v=>v.toFixed(2);let d=`M${f(pts[0].x)},${f(pts[0].y)}`;
    for(let i=0;i<pts.length-1;i++){const a=pts[i],b=pts[i+1],dx=b.x-a.x;
      d+=` C${f(a.x+dx/3)},${f(a.y+m[i]*dx/3)} ${f(b.x-dx/3)},${f(b.y-m[i+1]*dx/3)} ${f(b.x)},${f(b.y)}`;}
    return d;
  }
  function chart(){
    const root=document.getElementById('chart');root.replaceChildren();
    document.getElementById('chart-title').textContent=t(metric==='tokens'?'dailyTokens':'dailyCost');
    const series=providers.map(id=>({id,values:daySources.map(m=>value(m.get(id)))}));
    const peak=Math.max(0,...series.flatMap(x=>x.values));
    const scale=niceScale(peak),toY=v=>scale.max===0?VIEW_H:VIEW_H-v/scale.max*(VIEW_H-PLOT_TOP);
    const stepX=days.length<2?0:VIEW_W/(days.length-1);
    const axis=h('div',{class:'y-axis'});
    scale.ticks.forEach(v=>axis.append(h('span',{style:`top:${toY(v)/VIEW_H*100}%`},v===0?'0':format(v))));
    const svg=s('svg',{viewBox:`0 0 ${VIEW_W} ${VIEW_H}`,preserveAspectRatio:'none',role:'img','aria-label':t(metric==='tokens'?'dailyTokens':'dailyCost')});
    scale.ticks.forEach(v=>svg.append(s('line',{x1:0,x2:VIEW_W,y1:toY(v),y2:toY(v),stroke:'var(--border)','stroke-width':1,'vector-effect':'non-scaling-stroke'})));
    const drawn=series.map(x=>({...x,total:x.values.reduce((a,b)=>a+b,0),line:curve(x.values.map((v,i)=>({x:i*stepX,y:toY(v)})))}))
      .sort((a,b)=>b.total-a.total);
    for(const x of drawn)if(x.line)svg.append(s('path',{d:`${x.line} L${VIEW_W},${VIEW_H} L0,${VIEW_H} Z`,fill:presentation(x.id).color,'fill-opacity':.12}));
    for(const x of drawn){
      if(x.line)svg.append(s('path',{d:x.line,fill:'none',stroke:presentation(x.id).color,'stroke-width':2,'vector-effect':'non-scaling-stroke'}));
      else if(days.length===1)svg.append(s('circle',{cx:VIEW_W/2,cy:toY(x.values[0]),r:4,fill:presentation(x.id).color}));
    }
    const cursor=s('line',{y1:PLOT_TOP,y2:VIEW_H,stroke:'var(--muted-foreground)','stroke-width':1,'vector-effect':'non-scaling-stroke',visibility:'hidden'});
    svg.append(cursor);
    const plot=h('div',{class:'plot'},svg);
    const tip=h('div',{class:'chart-tip',hidden:true});plot.append(tip);
    plot.addEventListener('mousemove',event=>{
      const box=plot.getBoundingClientRect();if(!box.width||!days.length)return;
      const x=Math.min(box.width,Math.max(0,event.clientX-box.left)),y=Math.min(box.height,Math.max(0,event.clientY-box.top));
      const index=Math.min(days.length-1,Math.max(0,Math.round(x/box.width*(days.length-1))));
      cursor.setAttribute('x1',index*stepX);cursor.setAttribute('x2',index*stepX);cursor.setAttribute('visibility','visible');
      const day=days[index],values=daySources[index];
      tip.replaceChildren(h('div',{class:'when'},dayShort(day.day)+(day.recorded?'':' · '+t('noRecord'))),
        ...providers.map(id=>h('div',{class:'tip-row'},h('span',{class:'who'},mark(id,12),presentation(id).label),h('span',{class:'num fg'},format(value(values.get(id)))))),
        h('div',{class:'tip-row total'},h('span',{class:'muted'},t('total')),h('span',{class:'num fg'},format(value(day)))));
      tip.hidden=false;
      const gap=12,w=tip.offsetWidth,ht=tip.offsetHeight;
      const left=x+gap+w<=box.width?x+gap:x-gap-w,top=y+gap+ht<=box.height?y+gap:y-gap-ht;
      tip.style.left=Math.min(Math.max(0,left),Math.max(0,box.width-w))+'px';
      tip.style.top=Math.min(Math.max(0,top),Math.max(0,box.height-ht))+'px';
    });
    plot.addEventListener('mouseleave',()=>{tip.hidden=true;cursor.setAttribute('visibility','hidden');});
    const mid=days[Math.floor(days.length/2)];
    root.append(h('div',{class:'chart-row'},axis,plot),
      h('div',{class:'x-axis'},h('span',{},days[0]?dayShort(days[0].day):''),h('span',{},mid?dayShort(mid.day):''),h('span',{},days.at(-1)?dayShort(days.at(-1).day):'')));
  }

  function metrics(){
    const root=document.getElementById('metrics');root.replaceChildren();
    [['processedTokens',tokens(totals.total),count(totals.total)],['cachedInput',tokens(totals.cacheRead),count(totals.cacheRead)],
     ['uncachedInput',tokens(totals.input),count(totals.input)],['output',tokens(totals.output),count(totals.output)],
     ['cacheSavings',usd(breakdownCost.cacheSavings),usd(breakdownCost.cacheSavings)]]
      .forEach(([key,shown,exact])=>root.append(h('div',{class:'metric'},h('span',{class:'label'},t(key)),h('span',{class:'value',title:exact},shown))));
  }

  function shareBar(label,segments,fmt,aside){
    const visible=segments.filter(x=>x.value>0),total=visible.reduce((a,x)=>a+x.value,0);
    if(total<=0)return null;
    return h('div',{class:'share'},
      h('div',{class:'share-head'},h('h3',{},label),aside??null),
      h('div',{class:'share-bar',role:'img','aria-label':`${label}: ${visible.map(x=>`${x.label} ${fmt(x.value)}`).join(', ')}`},
        visible.map(x=>h('div',{style:`flex:${x.value} 1 0;background:${x.color}`,'data-tip':`${x.label} · ${fmt(x.value)} · ${percent(x.value/total)}`}))),
      h('div',{class:'share-legend'},visible.map(x=>h('span',{},h('i',{style:`background:${x.color}`,'aria-hidden':'true'}),h('span',{class:'muted'},x.label),h('span',{class:'num fg'},fmt(x.value))))));
  }
  function shares(){
    const root=document.getElementById('shares');root.replaceChildren();
    if(totals.total<=0)return;
    if(metric==='tokens'){
      root.append(shareBar(t('tokensByType'),[
        {label:t('input'),value:totals.input,color:TYPE_COLORS.input},{label:t('cacheRead'),value:totals.cacheRead,color:TYPE_COLORS.cacheRead},
        {label:t('cacheWrite'),value:totals.cacheWrite,color:TYPE_COLORS.cacheWrite},{label:t('output'),value:totals.output,color:TYPE_COLORS.output}],tokens)??'');
      return;
    }
    const c=breakdownCost;
    const byType=shareBar(t('costByType'),[
      {label:t('input'),value:c.input,color:TYPE_COLORS.input},{label:t('cacheRead'),value:c.cacheRead,color:TYPE_COLORS.cacheRead},
      {label:t('cacheWrite'),value:c.cacheWrite,color:TYPE_COLORS.cacheWrite},{label:t('output'),value:c.output,color:TYPE_COLORS.output}],usd);
    if(byType)root.append(byType);
    if(c.fast>0){
      const bySpeed=shareBar(t('costBySpeed'),[{label:t('standard'),value:Math.max(0,totals.cost-c.fast),color:ink(34)},{label:t('fast'),value:c.fast,color:ink(66)}],usd,
        h('span',{class:'share-aside'},t('premium')+' ',h('span',{class:'num fg'},usd(c.fastPremium))));
      if(bySpeed)root.append(bySpeed);
    }
  }

  function modelTable(){
    const rows=[...models].sort(metric==='tokens'?(a,b)=>b.total-a.total||b.cost-a.cost:(a,b)=>b.cost-a.cost||b.total-a.total);
    const peak=Math.max(0,...rows.map(value));
    const body=h('tbody');
    if(!rows.length)body.append(h('tr',{class:'empty-row'},h('td',{colspan:5},t('noActivity'))));
    rows.forEach((m,i)=>{
      const id=m.source??providers[0],v=value(m),bar=v>0&&peak>0;
      const share=metric==='tokens'?(totals.total>0?m.total/totals.total:null):(unknownCost(m)||!(totals.cost>0)?null:m.cost/totals.cost);
      body.append(h('tr',{},
        h('td',{},i+1),
        h('td',{},h('div',{class:'model-name',style:bar?'':'padding:4px 0'},mark(id,14),h('span',{},m.name)),
          bar?h('div',{class:'model-bar','aria-hidden':'true'},h('div',{style:`width:max(0.5rem, ${v/peak*100}%);background:${presentation(id).color}`})):null),
        h('td',{class:'cost',title:usd(m.cost)},unknownCost(m)?h('span',{class:'muted'},t('unpriced')):usd(m.cost)),
        h('td',{class:'share-col'},share==null?'':percent(share)),
        h('td',{title:count(m.total)},tokens(m.total))));
    });
    return h('table',{class:'models'},h('thead',{},h('tr',{},h('th',{},'#'),h('th',{},t('model')),h('th',{},t('cost')),h('th',{class:'share-col'},t('share')),h('th',{},t('tokens')))),body);
  }
  function dayTable(){
    const body=h('tbody');
    [...days].map((d,i)=>[d,daySources[i]]).reverse().forEach(([d,m])=>{
      const dash=()=>h('td',{},'—');
      body.append(h('tr',{class:d.recorded?'':'missing'},h('td',{},dayShort(d.day)),
        ...providers.map(id=>d.recorded?h('td',{title:usd(m.get(id)?.cost??0)},usd(m.get(id)?.cost??0)):dash()),
        d.recorded?h('td',{class:'total',title:usd(d.cost)},unknownCost(d)?t('unpriced'):usd(d.cost)):dash(),
        d.recorded?h('td',{title:count(d.total)},tokens(d.total)):h('td',{},t('noRecord'))));
    });
    return h('div',{class:'table-scroll',role:'region',tabindex:0,'aria-label':t('breakdown')},
      h('table',{class:'days'},h('thead',{},h('tr',{},h('th',{},t('day')),...providers.map(id=>h('th',{},presentation(id).label)),h('th',{},t('total')),h('th',{},t('tokens')))),body));
  }
  function breakdownSection(){
    document.getElementById('breakdown').replaceChildren(breakdown==='model'?modelTable():dayTable());
  }

  function render(){
    document.documentElement.lang=language==='zh'?'zh-Hans':'en';
    document.title=`QuotaBar · ${t('usage')}`;
    document.querySelectorAll('[data-i18n]').forEach(n=>{const v=t(n.dataset.i18n);if(typeof v==='string')n.textContent=v;});
    derive();
    const binds={periodName:t('periodName')(days.length),windowLabel:days.length?t('range')(dayShort(days[0].day),dayShort(days.at(-1).day)):''};
    document.querySelectorAll('[data-bind]').forEach(n=>n.textContent=binds[n.dataset.bind]??'');
    document.querySelector('[data-metric-group]').setAttribute('aria-label',t('metric'));
    document.querySelector('[data-language-group]').setAttribute('aria-label',t('language'));
    document.querySelector('[data-breakdown-group]').setAttribute('aria-label',t('breakdownGroup'));
    document.querySelector('[data-period-group]').setAttribute('aria-label',t('period'));
    document.querySelectorAll('[data-period]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.period===period)));
    const shown=periodRange(),inputs=document.querySelector('[data-range-inputs]');
    inputs.hidden=period!=='custom';
    for(const [selector,value,label] of [['[data-range-from]',shown.from,'rangeFrom'],['[data-range-to]',shown.to,'rangeTo']]){
      const input=document.querySelector(selector);
      input.min=FIRST_DAY<shown.from?FIRST_DAY:shown.from;input.max=LAST_DAY;input.value=value;input.setAttribute('aria-label',t(label));
    }
    document.querySelectorAll('[data-metric]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.metric===metric)));
    document.querySelectorAll('[data-language]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.language===language)));
    document.querySelectorAll('[data-breakdown]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.breakdown===breakdown)));
    summary();chart();metrics();shares();breakdownSection();
  }

  const STORE='quotabar-report:'+location.pathname;
  const save=()=>{try{localStorage.setItem(STORE,JSON.stringify({language,metric,breakdown,period,range}));}catch{}};
  function setLanguage(next){language=next==='en'?'en':'zh';save();render();}
  window.setReportLanguage=setLanguage;
  // Called by the app with a newer snapshot. The chosen view stays; a custom end past the new
  // last day is clamped like a stored one.
  window.updateReport=next=>{
    load(next);
    if(period==='custom'&&range.to>LAST_DAY)range={...range,to:LAST_DAY};
    render();
  };
  document.querySelectorAll('[data-language]').forEach(b=>b.addEventListener('click',()=>setLanguage(b.dataset.language)));
  document.querySelectorAll('[data-metric]').forEach(b=>b.addEventListener('click',()=>{metric=b.dataset.metric;save();render();}));
  document.querySelectorAll('[data-breakdown]').forEach(b=>b.addEventListener('click',()=>{breakdown=b.dataset.breakdown;save();render();}));
  document.querySelectorAll('[data-period]').forEach(b=>b.addEventListener('click',()=>{
    if(b.dataset.period==='custom'&&period!=='custom')range=periodRange();
    period=b.dataset.period;save();render();
    if(period==='custom')document.querySelector('[data-range-from]').focus();
  }));
  const clampDay=day=>day>LAST_DAY?LAST_DAY:day;
  for(const [selector,key] of [['[data-range-from]','from'],['[data-range-to]','to']]){
    document.querySelector(selector).addEventListener('change',event=>{
      if(!/^\d{4}-\d{2}-\d{2}$/.test(event.target.value))return;
      range={...periodRange(),[key]:clampDay(event.target.value)};period='custom';save();render();
    });
  }

  // One shared tooltip for share-bar segments and the unpriced notice.
  const tip=document.getElementById('tip');
  const showTip=target=>{
    tip.textContent=target.dataset.tip;tip.hidden=false;
    const r=target.getBoundingClientRect(),w=tip.offsetWidth,ht=tip.offsetHeight;
    tip.style.left=Math.min(innerWidth-w-8,Math.max(8,r.left+r.width/2-w/2))+'px';
    tip.style.top=(r.top-ht-8<8?r.bottom+8:r.top-ht-8)+'px';
  };
  const tipTarget=e=>e.target instanceof Element?e.target.closest('[data-tip]'):null;
  document.addEventListener('pointerover',e=>{const x=tipTarget(e);if(x)showTip(x);else tip.hidden=true;});
  document.addEventListener('focusin',e=>{const x=tipTarget(e);if(x)showTip(x);});
  document.addEventListener('focusout',()=>{tip.hidden=true;});
  addEventListener('scroll',()=>{tip.hidden=true;},{passive:true});

  let stored={};
  try{stored=JSON.parse(localStorage.getItem(STORE)??'{}')??{};}catch{}
  const params=new URLSearchParams(location.search);
  language=(params.get('lang')??stored.language)==='en'?'en':'zh';
  metric=(params.get('metric')??stored.metric)==='tokens'?'tokens':'cost';
  breakdown=(params.get('breakdown')??stored.breakdown)==='day'?'day':'model';
  const isDay=v=>typeof v==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(v);
  const storedRange=stored.range&&isDay(stored.range.from)&&isDay(stored.range.to)?{from:stored.range.from,to:clampDay(stored.range.to)}:null;
  const requested=params.get('period')??stored.period;
  if(isDay(params.get('from'))&&isDay(params.get('to'))){period='custom';range={from:params.get('from'),to:clampDay(params.get('to'))};}
  else if(requested==='custom'&&storedRange){period='custom';range=storedRange;}
  else period=requested==='7'||requested==='30'?requested:DEFAULT_PERIOD;
  render();
})();
