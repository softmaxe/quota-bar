// Fixed bilingual report copy and the original F2, G3, and G4 chart implementations.
// Chart geometry comes from the chart skill's Basics and Glance galleries.
(() => {
  const COMMON_COPY = {
    zh: {
      totalLabel:'Token 总用量',costLabel:'已存 API 费用',cacheReadLabel:'缓存读取',cacheWriteLabel:'缓存写入',
      cacheShareLabel:'输入侧缓存占比',unpricedLabel:'未定价 tokens',periodLabel:'统计区间',sourceLabel:'本地已存数据',generatedLabel:'快照生成于',
      dailyTitle:'用量在哪天达到峰值',dailyNote:'一点代表一天，空心点表示周末。悬停查看数值，或展开下方的数据明细。',
      modelsTitle:'哪些模型费用最多',modelsNote:'前三个模型与其余模型合计。条形从零开始，仅含已定价费用。',
      compositionTitle:'Tokens 用在了哪里',compositionNote:'每个圆点代表总量的 1%。空心点是舍入余量，右侧显示实际比例。',
      costNote:'* 为部分费用估算，未定价 tokens 未计入。金额来自已存 API 估算，不是实际账单。',
      fullCostNote:'金额来自已存 API 费用估算，不是实际账单。',
      unpricedCostNote:'此区间的用量均未定价，无法提供费用估算。',
      cacheCostNote:'历史数据没有单独保存缓存读取、写入费用，因此这里只展示缓存 token 用量。',
      dataNote:'缺记录日期不代表零使用。今天的数据截至快照生成时。',
      cacheFormula:'输入侧缓存占比 = 缓存读取 / 新增输入、缓存写入与缓存读取之和。Token 构成图以全部 tokens 为分母。缓存写入已包含一小时 TTL 子集，不重复计数。',
      detailsLabel:'查看每日与模型明细',dailyTableLabel:'每日明细',modelsTableLabel:'全部模型',dateLabel:'日期',modelLabel:'模型',
      unitNote:'K = 千 · M = 百万 · B = 十亿 · T = 万亿 · Q = 千万亿',recordedDays:'天有记录',
      dailySource:'本地每日汇总 · × = 无记录 · 日期为本地日历日',
      modelsSource:'本地模型费用 · 亮色表示费用较高 · USD',
      compositionSource:'本地 token 分项 · 空心点为向下取整后的余量',
      empty:'此区间没有已存记录',noTokens:'此区间没有 token 用量',unpriced:'未定价',other:'其他模型',
      input:'新增输入',output:'输出',cacheRead:'缓存读取',cacheWrite:'缓存写入',rounding:'舍入余量',
      dailyLegend:'一点 = 一天 · 空心 = 周末 · × = 无记录',noRecord:'无记录',tokens:'tokens',partial:'部分估算',
      zeroDailyTitle:'本期已存用量为零',missingDailyTitle:'本期没有每日记录',noCost:'本期没有非零已存模型费用',noPricedCost:'本期没有已定价模型费用',
      compositionTableLabel:'Token 构成',componentLabel:'分项',shareLabel:'占全部 tokens',languageLabel:'语言',timeZoneLabel:'日期时区',noUsage:'暂无用量',scrollHint:'横向滚动查看完整趋势，也可展开下方明细。',
    },
    en: {
      totalLabel:'Total tokens',costLabel:'Stored API cost',cacheReadLabel:'Cache read',cacheWriteLabel:'Cache write',
      cacheShareLabel:'Input-side cache share',unpricedLabel:'Unpriced tokens',periodLabel:'Period',sourceLabel:'Stored local data',generatedLabel:'Snapshot created',
      dailyTitle:'When usage peaked',dailyNote:'One point per day. Hollow points mark weekends. Hover for values, or expand the data details below.',
      modelsTitle:'Which models cost the most',modelsNote:'Top three models plus all others. Bars start at zero and include priced usage only.',
      compositionTitle:'Where the tokens went',compositionNote:'Each dot is 1% of all tokens. Hollow dots are rounding remainders. The key shows actual shares.',
      costNote:'* Partial estimate. Unpriced tokens are excluded. Stored API estimates are not actual bills.',
      fullCostNote:'Amounts are stored API cost estimates, not actual bills.',
      unpricedCostNote:'All usage in this period is unpriced. No cost estimate is available.',
      cacheCostNote:'Historical cache read and write costs were not stored separately. Only cache token counts are shown.',
      dataNote:'Missing dates do not mean zero usage. Today ends at snapshot time.',
      cacheFormula:'Input-side cache share = cache read / the sum of new input, cache write and cache read. The composition chart uses all tokens as its denominator. Cache write includes its one-hour TTL subset once.',
      detailsLabel:'View daily and model details',dailyTableLabel:'Daily details',modelsTableLabel:'All models',dateLabel:'Date',modelLabel:'Model',
      unitNote:'K = thousand · M = million · B = billion · T = trillion · Q = quadrillion',recordedDays:'days recorded',
      dailySource:'Local daily totals · × = no record · Local calendar dates',
      modelsSource:'Stored model costs · Brighter means higher cost · USD',
      compositionSource:'Stored token components · Hollow dots are rounding remainders',
      empty:'No stored records in this period',noTokens:'No token usage in this period',unpriced:'Unpriced',other:'Other models',
      input:'New input',output:'Output',cacheRead:'Cache read',cacheWrite:'Cache write',rounding:'Rounding',
      dailyLegend:'One point = one day · Hollow = weekend · × = no record',noRecord:'No record',tokens:'tokens',partial:'Partial estimate',
      zeroDailyTitle:'Recorded usage is zero',missingDailyTitle:'No daily records in this period',noCost:'No nonzero stored model costs',noPricedCost:'No priced model costs in this period',
      compositionTableLabel:'Token composition',componentLabel:'Component',shareLabel:'Share of all tokens',languageLabel:'Language',timeZoneLabel:'Calendar timezone',noUsage:'No usage',scrollHint:'Scroll sideways for the full trend, or expand the details below.',
    },
  };
  const {el,txt,tip}=MONO,T=CHART_THEME;
  let language='zh';
  const copy=key=>{
    if(key==='dailyTitle'&&!REPORT.totals.total)key=REPORT.days.some(row=>row.recorded)?'zeroDailyTitle':'missingDailyTitle';
    if(key==='modelsTitle'&&!REPORT.totals.cost)key=REPORT.totals.unpricedTokens>0?'noPricedCost':'noCost';
    if(key==='costNote'){
      if(REPORT.totals.total>0&&REPORT.totals.unpricedTokens>=REPORT.totals.total)key='unpricedCostNote';
      else if(!REPORT.totals.unpricedTokens)key='fullCostNote';
    }
    return PAGE_COPY[language]?.[key]??COMMON_COPY[language][key]??key;
  };
  const number=v=>v.toLocaleString('en-US',{maximumFractionDigits:0});
  const compact=v=>{
    const tier=[[1e15,'Q'],[1e12,'T'],[1e9,'B'],[1e6,'M'],[1e3,'K']].find(([scale])=>v>=scale);
    return tier?(v/tier[0]).toFixed(tier[0]===1e3?1:2)+tier[1]:number(v);
  };
  const axisNumber=v=>Number.isInteger(v)?compact(v):v.toLocaleString('en-US',{maximumFractionDigits:2});
  const money=v=>'$'+v.toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});
  const cost=row=>row.total>0&&row.unpricedTokens>=row.total?copy('unpriced'):money(row.cost)+(row.unpricedTokens>0?' *':'');
  const percent=v=>(v*100).toFixed(2)+'%';
  const nice=v=>v>0?Math.ceil(v/10**Math.floor(Math.log10(v)))*10**Math.floor(Math.log10(v)):1;
  const label=(s,x,y,text,extra={})=>txt(s,{x,y,'font-size':8,'font-weight':600,fill:T.MUT,...extra},text);
  const active=REPORT.days.filter(d=>d.recorded);
  const peak=[...active].sort((a,b)=>b.total-a.total)[0];
  const models=[...REPORT.models].sort((a,b)=>b.cost-a.cost||b.total-a.total);
  const costModels=models.filter(row=>row.cost>0),top=costModels[0];
  const reduced=()=>window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  function fields(){
    const t=REPORT.totals;
    return {totalTokens:active.length?compact(t.total):copy('noRecord'),cost:active.length?cost(t):copy('noRecord'),cacheRead:active.length?compact(t.cacheRead):copy('noRecord'),cacheWrite:active.length?compact(t.cacheWrite):copy('noRecord'),
      cacheShare:t.input+t.cacheRead+t.cacheWrite?percent(t.cacheRead/(t.input+t.cacheRead+t.cacheWrite)):'N/A',
      unpricedTokens:compact(t.unpricedTokens),period:REPORT.days[0].day+(language==='zh'?' 至 ':' to ')+REPORT.days.at(-1).day,
      capturedAt:REPORT.capturedAt.replace('T',' ').replace(/(?:\.\d+)?Z$/,' UTC'),sourceNames:REPORT.sources.map(x=>x.name).join(' · ')||copy('noRecord'),timeZone:REPORT.timezone,
      activeDays:active.length,calendarDays:REPORT.days.length,modelCount:models.length,
      peakDay:peak?.total?peak.day:copy('noUsage'),peakTokens:compact(peak?.total??0),
      topModel:top?.name??copy(REPORT.totals.unpricedTokens?'noPricedCost':'noCost'),topModelCost:top?cost(top):copy('noRecord'),
      pricingCoverage:t.total?percent((t.total-t.unpricedTokens)/t.total):'N/A'};
  }
  function accessible(s,text){s.setAttribute('role','img');s.setAttribute('aria-label',text);}
  function empty(s,text){
    const W=s.viewBox.baseVal.width;
    accessible(s,text);el(s,'line',{x1:24,y1:262,x2:W-24,y2:262,stroke:T.GRID});
    label(s,W/2,150,text,{'text-anchor':'middle','font-size':12});
  }

  // F2, Hairline Line: preserve the calendar floor, daily points, separated peaks, and line.
  function daily(s){
    if(!active.length){empty(s,copy('empty'));return;}
    const W=s.viewBox.baseVal.width,D=REPORT.days,N=D.length,x=d=>70+d*(W-100)/Math.max(1,N-1),base=262,max=nice(Math.max(...D.map(d=>d.total))),map=v=>base-v/max*205;
    accessible(s,copy('dailyNote'));
    D.forEach((_,d)=>el(s,'line',{x1:x(d),y1:base,x2:x(d),y2:base-7,stroke:T.LINE,'stroke-width':.6}));
    el(s,'line',{x1:64,y1:base,x2:W-24,y2:base,stroke:T.GRID,'stroke-width':.8});
    const hasTokens=D.some(row=>row.total>0);
    (hasTokens?[0,max/2,max]:[0]).forEach(v=>label(s,55,map(v)+4,axisNumber(v),{'font-size':11,'text-anchor':'end'}));
    const peaks=[];
    for(const d of [...D.keys()].filter(i=>D[i].recorded&&D[i].total>0).sort((a,b)=>D[b].total-D[a].total)){
      if(peaks.every(t=>Math.abs(t-d)>=6))peaks.push(d);
      if(peaks.length===2)break;
    }
    let path='',connected=false;
    D.forEach((row,d)=>{if(!row.recorded){connected=false;return;}path+=(connected?' L ':' M ')+`${x(d)} ${map(row.total)}`;connected=true;});
    if(path)el(s,'path',{d:path,fill:'none',stroke:T.HERO,'stroke-width':1,pathLength:1,class:'draw',style:'animation-duration:1.2s'});
    D.forEach((row,d)=>{
      if(!row.recorded){const mark=label(s,x(d),base+3,'×',{'text-anchor':'middle'});tip(mark,row.day+' · '+copy('noRecord'));return;}
      const weekend=[0,6].includes(new Date(row.day+'T12:00:00Z').getUTCDay()),big=peaks.includes(d);
      const dot=el(s,'circle',{cx:x(d),cy:map(row.total),r:big?4.2:2.1,fill:weekend?T.PAGE:T.HERO,stroke:T.HERO,'stroke-width':weekend?1:0,class:'pop',style:`animation-delay:${.2+d*.012}s`});
      tip(dot,`${row.day} · ${number(row.total)} tokens · ${copy('cacheRead')} ${number(row.cacheRead)} · ${copy('costLabel')} ${cost(row)}`);
      if(big)label(s,x(d),map(row.total)-11,compact(row.total),{'font-size':11.5,'font-weight':800,fill:T.HERO,'text-anchor':d>N-4?'end':d<3?'start':'middle',style:`paint-order:stroke;stroke:${T.PAGE};stroke-width:3px`});
    });
    [...new Set([0,Math.floor((N-1)/2),N-1])].forEach(d=>label(s,x(d),base+24,D[d].day.slice(5),{'text-anchor':'middle','font-size':11}));
    label(s,W/2,307,copy('dailyLegend'),{'text-anchor':'middle','font-size':W>500?10:9});
  }

  // G3, Chunky Bars: retain vertical zero-based bars, capsule tops, exact top labels, and stagger.
  const instances=new Map();
  function modelBars(canvas){
    instances.get(canvas)?.destroy();
    const D=costModels.slice(0,3).map(x=>({...x}));
    if(costModels.length>3)D.push({name:copy('other'),cost:costModels.slice(3).reduce((n,x)=>n+x.cost,0),total:costModels.slice(3).reduce((n,x)=>n+x.total,0),unpricedTokens:costModels.slice(3).reduce((n,x)=>n+x.unpricedTokens,0)});
    const colors=[...D].sort((a,b)=>a.cost-b.cost);
    const shade=row=>T.RAMP[Math.max(2,Math.round(2+colors.indexOf(row)/Math.max(1,D.length-1)*2))];
    accessible(canvas,copy('modelsNote')+' '+D.map(x=>x.name+': '+cost(x)).join('; '));
    const labels=D.map(row=>{
      if(row.name===copy('other'))return language==='en'?['Other','models']:row.name;
      const bits=row.name.split('-');
      const lines=bits.length>2?[bits.slice(0,2).join('-'),bits.slice(2).join('-')]:[row.name];
      return lines.map(line=>line.length>15?line.slice(0,14)+'…':line);
    });
    instances.set(canvas,new Chart(canvas,{
      type:'bar',data:{labels,datasets:[{data:D.map(row=>row.cost),backgroundColor:D.map(shade),borderRadius:{topLeft:99,topRight:99},borderSkipped:false,barPercentage:.52}]},
      options:{maintainAspectRatio:false,layout:{padding:{top:22,right:6,left:6}},
        animation:reduced()?false:{duration:900,easing:'easeOutQuart',delay:c=>c.type==='data'?c.dataIndex*110:0},
        plugins:{legend:{display:false},tooltip:{backgroundColor:T.HERO,titleColor:T.ON_HI,bodyColor:T.ON_HI,padding:12,cornerRadius:12,displayColors:false,callbacks:{title:items=>D[items[0].dataIndex].name,label:item=>cost(D[item.dataIndex])+' · '+number(D[item.dataIndex].total)+' tokens'}}},
        scales:{x:{grid:{display:false},border:{display:false},ticks:{color:T.MUT,padding:8,maxRotation:0,autoSkip:false,font:{family:'Inter, Arial',size:10,weight:600}}},y:{display:false,min:0,max:Math.max(1,...D.map(x=>x.cost))*1.18}}},
      plugins:[{id:'topValues',afterDatasetsDraw(chart){
        const {ctx}=chart;
        if(!D.length){ctx.save();ctx.fillStyle=T.MUT;ctx.font='12px Arial';ctx.textAlign='center';ctx.fillText(copy(REPORT.totals.unpricedTokens?'noPricedCost':'noCost'),chart.width/2,chart.height/2);ctx.restore();return;}
        chart.getDatasetMeta(0).data.forEach((bar,i)=>{
          ctx.save();ctx.font='700 11px Inter, Arial';ctx.fillStyle=T.HERO;ctx.textAlign='center';
          const text=D[i].cost>=10000?'$'+compact(D[i].cost)+(D[i].unpricedTokens?' *':''):cost(D[i]);
          ctx.fillText(text,bar.x,bar.y-10);ctx.restore();
        });
      }}],
    }));
  }

  // G4, Dot Waffle: preserve the 10x10 circle grid and right-hand key.
  // Floor each share; outlined remainder dots avoid inventing fractional records.
  function composition(s){
    const t=REPORT.totals;if(!t.total){empty(s,copy('noTokens'));return;}
    const D=[['cacheRead',t.cacheRead,T.CAT[2]],['input',t.input,T.CAT[0]],['cacheWrite',t.cacheWrite,T.CAT[1]],['output',t.output,T.CAT[3]]];
    accessible(s,copy('compositionNote')+' '+D.map(([name,value])=>copy(name)+': '+number(value)+' tokens, '+percent(value/t.total)).join('; '));
    s=el(s,'g',{transform:'translate(0 36)'});
    const COLS=10,CELL=21,R=7.5,X0=8,Y0=10;
    let idx=0;
    D.forEach(([name,value,color],g)=>{
      for(let k=0;k<Math.floor(value/t.total*100);k++,idx++){
        const dot=el(s,'circle',{cx:X0+idx%COLS*CELL+R,cy:Y0+Math.floor(idx/COLS)*CELL+R,r:R,fill:color,class:'pop',style:`animation-delay:${idx*.008+g*.05}s`});
        tip(dot,copy(name)+' · '+number(value)+' tokens · '+percent(value/t.total));
      }
    });
    const remainder=100-idx;
    for(;idx<100;idx++){const dot=el(s,'circle',{cx:X0+idx%COLS*CELL+R,cy:Y0+Math.floor(idx/COLS)*CELL+R,r:R,fill:'none',stroke:T.MUT,'stroke-width':1});tip(dot,copy('rounding'));}
    D.forEach(([name,value,color],g)=>{
      const y=26+g*44;
      el(s,'circle',{cx:246,cy:y,r:6,fill:color});
      label(s,260,y-1,copy(name),{'font-size':10.5,fill:T.LAB});
      const val=label(s,260,y+22,percent(value/t.total),{'font-size':15,'font-weight':800,fill:T.HERO});tip(val,number(value)+' tokens');
    });
    el(s,'circle',{cx:246,cy:210,r:6,fill:'none',stroke:T.MUT,'stroke-width':1});
    label(s,260,208,copy('rounding'),{'font-size':9});label(s,260,231,number(remainder)+'%',{'font-size':12,fill:T.LAB});
  }
  const renderers={daily,models:modelBars,composition};
  const charts=[...document.querySelectorAll('[data-chart]')];
  const scrollRegion=document.querySelector('[data-scroll-region]');
  function updateScrollRegion(){
    if(!scrollRegion)return;
    const scrolls=scrollRegion.scrollWidth>scrollRegion.clientWidth+1;
    scrollRegion.setAttribute('aria-label',copy('dailyTitle')+(scrolls?'. '+copy('scrollHint'):''));
    if(scrolls)scrollRegion.tabIndex=0;else scrollRegion.removeAttribute('tabindex');
    document.querySelectorAll('[data-scroll-hint]').forEach(node=>node.hidden=!scrolls);
  }
  if(scrollRegion)new ResizeObserver(updateScrollRegion).observe(scrollRegion);
  charts.forEach(chart=>{
    MONO.obsReveal(chart.id,renderers[chart.dataset.chart]);
    chart.setAttribute('aria-describedby','data-summary');
  });
  function setLanguage(next){
    language=next==='en'?'en':'zh';document.documentElement.lang=language==='zh'?'zh-Hans':'en';
    document.documentElement.dataset.defaultLanguage=language;
    const values=fields();
    document.querySelectorAll('[data-i18n]').forEach(n=>n.textContent=copy(n.dataset.i18n));
    document.title='QuotaBar · '+copy('pageTitle');
    document.querySelectorAll('[data-language-group]').forEach(n=>n.setAttribute('aria-label',copy('languageLabel')));
    document.querySelectorAll('[data-summary="daily-peak"]').forEach(n=>n.hidden=!peak?.total);
    document.querySelectorAll('[data-summary="model-cost"]').forEach(n=>n.hidden=!top);
    document.querySelectorAll('[data-bind]').forEach(n=>n.textContent=values[n.dataset.bind]??'');
    document.querySelectorAll('[data-bind="cacheShare"]').forEach(n=>n.title=copy('cacheFormula'));
    function tableRows(id,rows){
      const body=document.getElementById(id);if(!body)return;
      body.replaceChildren();rows.forEach(row=>{const tr=document.createElement('tr');row.forEach((value,i)=>{const cell=document.createElement(i===0?'th':'td');if(i===0)cell.scope='row';cell.textContent=value;tr.appendChild(cell);});body.appendChild(tr);});
    }
    tableRows('daily-table',REPORT.days.map(row=>[row.day,...[row.total,row.cacheRead,row.cacheWrite].map(v=>row.recorded?number(v):copy('noRecord')),row.recorded?cost(row):copy('noRecord')]));
    tableRows('model-table',models.map(row=>[row.name,number(row.total),cost(row)]));
    tableRows('composition-table',['cacheRead','input','cacheWrite','output'].map(key=>[copy(key),number(REPORT.totals[key]),REPORT.totals.total?percent(REPORT.totals[key]/REPORT.totals.total):copy('noUsage')]));
    document.querySelectorAll('[data-language]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.language===language)));
    charts.forEach(chart=>{if(chart.tagName.toLowerCase()==='svg')chart.innerHTML='';renderers[chart.dataset.chart](chart);});
    updateScrollRegion();
    try{localStorage.setItem('quotabar-report-language:'+location.pathname,language);}catch{}
    if(parent!==window)parent.postMessage({type:'quotabar-report-language',language},'*');
  }
  window.setReportLanguage=setLanguage;
  document.querySelectorAll('[data-language]').forEach(button=>button.addEventListener('click',()=>setLanguage(button.dataset.language)));
  let initial=new URLSearchParams(location.search).get('lang');
  if(!initial)try{initial=localStorage.getItem('quotabar-report-language:'+location.pathname);}catch{}
  setLanguage(initial||document.documentElement.dataset.defaultLanguage||'zh');
})();
