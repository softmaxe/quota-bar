// Browser regression checks for the native usage report page.
import assert from 'node:assert/strict';
import {readFileSync,realpathSync,mkdirSync,writeFileSync,rmSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';

const args=process.argv.slice(2);
const option=(key,fallback)=>args.includes(key)?args[args.indexOf(key)+1]:fallback;
const file=resolve(option('--file','build/usage-report.html'));
const output=resolve(option('--output','build/usage-report-browser'));
mkdirSync(output,{recursive:true});
const source=readFileSync(file,'utf8');
const match=source.match(/const REPORT=(.*);\n\/\* Report runtime \*\//);
assert(match,'Expected the native report output');
const snapshot=JSON.parse(match[1]);
for(const script of source.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/g))execFileSync(process.execPath,['--check','-'],{input:script[1],stdio:['pipe','pipe','pipe']});
assert(!/<(?:script|link|img)[^>]+(?:src|href)=["']https?:/i.test(source));
const modulePath=process.env.PLAYWRIGHT_MODULE||realpathSync(execFileSync('which',['playwright-cli'],{encoding:'utf8'}).trim());
const {chromium}=createRequire(modulePath)('playwright');
const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH||'/Applications/Brave Browser.app/Contents/MacOS/Brave Browser'});
const context=await browser.newContext({viewport:{width:1280,height:960},reducedMotion:'reduce'});
let external=0;await context.route(/^https?:/,route=>{external++;return route.abort();});
const errors=[],results=[];
const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
const reportFile=join(output,'case.html');
const safeJSON=data=>JSON.stringify(data).replace(/</g,'\\u003c').replace(/\u2028/g,'\\u2028').replace(/\u2029/g,'\\u2029');
async function load(data=snapshot,query='lang=en'){
  writeFileSync(reportFile,source.replace(match[0],()=>`const REPORT=${safeJSON(data)};\n/* Report runtime */`));
  await page.evaluate(()=>{try{localStorage.clear();}catch{}}).catch(()=>{});
  await page.goto(pathToFileURL(reportFile).href+'?'+query);
  await page.waitForFunction(()=>typeof window.setReportLanguage==='function');
}
const hero=()=>page.locator('.hero-value').textContent();
async function layout(){
  return page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,
    escaped:[...document.querySelectorAll('.page *')].filter(n=>n.getBoundingClientRect().right>innerWidth+2&&!n.closest('.table-scroll')).length}));
}
async function checkLanguage(language){
  await page.locator(`[data-language=${language}]`).click();
  assert.equal(await page.locator('html').getAttribute('lang'),language==='en'?'en':'zh-Hans');
  const untranslated=await page.locator('[data-i18n]').evaluateAll(nodes=>nodes.filter(n=>n.textContent===n.dataset.i18n).map(n=>n.dataset.i18n));
  assert.deepEqual(untranslated,[]);
  if(language==='en'){
    const cjk=await page.evaluate(()=>[...document.querySelectorAll('.topbar :not([data-language]),.page *')]
      .filter(n=>!n.children.length&&/[㐀-鿿]/.test(n.textContent)).map(n=>n.textContent));
    assert.deepEqual(cjk,[],'English view shows no Chinese copy');
  }
}

// Synthetic history: one source per day so period sums are easy to check.
const FIELDS=['input','output','cacheRead','cacheWrite','cacheWrite1h','cost','unpricedTokens','total'];
function totals(v,{unpriced=false}={}){return {input:v/10,output:v/5,cacheRead:v*7/10,cacheWrite:0,cacheWrite1h:0,total:v,unpricedTokens:unpriced?v:0,cost:unpriced?0:v/100};}
function fixture(values,{unpriced=false,long=false,window=values.length}={}){
  const name=long?'provider/'+('long-model-name-'.repeat(12)):'fixture-model';
  const history=values.map((v,i)=>{
    const day=new Date(Date.UTC(2026,7,1+i)).toISOString().slice(0,10),t=totals(v??0,{unpriced});
    const row=v===null?[]:[{name:'Codex',source:'codex',...t}];
    return {day,recorded:v!==null,...t,sources:row,models:v===null?[]:[{name,source:'codex',...t}],
      costBreakdown:{input:t.cost*.1,output:t.cost*.4,cacheRead:t.cost*.5,cacheWrite:0,cacheSavings:t.cost,fast:0,fastPremium:0}};
  });
  const days=history.slice(-window);
  const sum=rows=>Object.fromEntries(FIELDS.map(k=>[k,rows.reduce((n,d)=>n+d[k],0)]));
  const t=sum(days),active=days.some(x=>x.recorded);
  return {period:'Fixture period',capturedAt:'2026-09-15T12:00:00Z',timezone:'Asia/Shanghai',totals:t,
    costBreakdown:{input:0,output:0,cacheRead:0,cacheWrite:0,cacheSavings:0,fast:0,fastPremium:0},days,history,
    models:active?[{name,source:'codex',...t}]:[],sources:active?[{name:'Codex',source:'codex',...t}]:[],weekdays:[]};
}
const usd=v=>'$'+v.toLocaleString('en-US',{minimumFractionDigits:2,maximumFractionDigits:2});

try{
  await load();
  for(const language of ['zh','en']){
    await checkLanguage(language);
    const metrics=await layout();
    assert(metrics.scrollWidth<=metrics.width+2,'Desktop overflow');
    assert.equal(metrics.escaped,0,'Content escapes the page');
    assert.equal(await page.locator('[data-chart=daily] svg path').count()>0||snapshot.totals.total===0,true,'Daily chart draws its series');
    await page.screenshot({path:join(output,'native-'+language+'.png'),fullPage:true});
    results.push({case:'native-'+language,...metrics});
  }
  await page.locator('[data-metric=tokens]').click();
  assert.equal(await page.locator('[data-metric=tokens]').getAttribute('aria-pressed'),'true');
  await page.locator('[data-breakdown=day]').click();
  assert.equal(await page.locator('.days tbody tr').count(),snapshot.days.length,'Day breakdown lists every day in the default period');
  await page.locator('[data-language=zh]').click();await page.goto(pathToFileURL(reportFile).href);
  assert.equal(await page.locator('html').getAttribute('lang'),'zh-Hans','Language choice persists for the exported file');
  assert.equal(await page.locator('[data-metric=tokens]').getAttribute('aria-pressed'),'true','Metric choice persists for the exported file');
  for(const width of [640,390]){
    await page.setViewportSize({width,height:700});
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+2),'Narrow report body must reflow');
    await page.screenshot({path:join(output,'native-'+width+'.png'),fullPage:true});
  }
  await page.setViewportSize({width:1280,height:960});

  // Period switching sums the embedded history; values are dollars per day.
  const series=Array.from({length:40},(_,i)=>i===35?null:(i+1)*100);
  await load(fixture(series,{window:7}));
  assert.equal(await page.locator('[data-period="7"]').getAttribute('aria-pressed'),'true','The export period is the default view');
  const sumCost=(from,to)=>series.slice(from,to).reduce((n,v)=>n+(v??0)/100,0);
  assert.equal(await hero(),usd(sumCost(33,40)));
  await page.locator('[data-period="30"]').click();
  assert.equal(await hero(),usd(sumCost(10,40)));
  assert.equal(await page.locator('.crumb.current').textContent(),'30 days');
  await page.locator('[data-period=custom]').click();
  assert(await page.locator('[data-range-inputs]').isVisible(),'Custom period shows its date fields');
  await page.locator('[data-range-from]').fill('2026-08-01');await page.locator('[data-range-from]').dispatchEvent('change');
  assert.equal(await hero(),usd(sumCost(0,40)),'Custom period covers the whole history');
  assert.equal(await page.locator('.crumb.current').textContent(),'40 days');
  await page.locator('[data-breakdown=day]').click();
  assert.equal(await page.locator('.days tbody tr.missing').count(),1,'A missing date stays distinct from recorded zero');
  assert.equal(await page.locator('.days tbody tr.missing td').last().textContent(),'No record');
  await page.reload();
  assert.equal(await page.locator('.crumb.current').textContent(),'40 days','Custom period persists for the exported file');
  await page.goto(pathToFileURL(reportFile).href+'?lang=en&from=2026-08-10&to=2026-08-01');
  assert.equal(await hero(),usd(sumCost(0,10)),'A reversed custom period is read in date order');
  await page.screenshot({path:join(output,'custom-period.png'),fullPage:true});
  results.push({case:'periods',passed:true});

  await load(fixture(Array(7).fill(0)));
  assert.equal(await hero(),'$0.00');
  assert(!(await page.locator('body').innerText()).includes('NaN'));
  results.push({case:'recorded-zero',passed:true});
  await load(fixture(Array(7).fill(100),{unpriced:true}));
  assert.equal(await hero(),'Unpriced');
  assert.equal(await page.locator('.models td.cost').first().textContent(),'Unpriced');
  results.push({case:'all-unpriced',passed:true});
  await load(fixture(Array(7).fill(100),{long:true}));
  assert((await page.locator('.model-name').first().textContent()).length>100);
  assert.equal((await layout()).escaped,0,'A long model name wraps inside the page');
  await page.screenshot({path:join(output,'long-model.png'),fullPage:true});
  results.push({case:'long-model',passed:true});
  await load(fixture(Array(7).fill(1e12)));
  assert((await page.locator('.metric .value').first().textContent()).endsWith('T'));
  results.push({case:'large-values',passed:true});
  assert.deepEqual(errors,[]);assert.equal(external,0);
  writeFileSync(join(output,'verification.json'),JSON.stringify({results,errors,external},null,2)+'\n');
  console.log('Passed native report: bilingual copy, persistence, 7/30/custom periods, missing/zero dates, pricing states, offline, narrow windows, and long model IDs.');
}finally{rmSync(reportFile,{force:true});await browser.close();}
