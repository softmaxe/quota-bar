// Browser regression checks for the actual single-file native export.
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
async function load(data=snapshot){
  writeFileSync(reportFile,source.replace(match[0],()=>`const REPORT=${safeJSON(data)};\n/* Report runtime */`));
  await page.goto(pathToFileURL(reportFile).href+'?lang=en');
  await page.waitForFunction(()=>typeof window.setReportLanguage==='function');
}
async function layout(){
  return page.evaluate(()=>{
    const rect=n=>{const b=n.getBoundingClientRect();return {x:b.x,y:b.y,width:b.width,height:b.height,bottom:b.bottom,right:b.right};};
    const columns=[...document.querySelectorAll('.compare>.b')];
    const bounds=columns.map(n=>({column:rect(n),heading:rect(n.querySelector('.state')),chart:rect(n.querySelector('.fig')),source:rect(n.querySelector('.srcline'))}));
    const labels=[...document.querySelectorAll('svg text')].map(n=>({text:n.textContent,...rect(n),svg:rect(n.ownerSVGElement)}));
    return {bounds,line:rect(document.querySelector('#daily')),width:innerWidth,scrollWidth:document.documentElement.scrollWidth,
      escapedLabels:labels.filter(n=>n.x<n.svg.x-2||n.right>n.svg.right+2||n.y<n.svg.y-2||n.bottom>n.svg.bottom+2)};
  });
}
async function checkLanguage(language,expectedDays){
  await page.locator(`[data-language=${language}]`).click();
  assert.equal(await page.locator('html').getAttribute('lang'),language==='en'?'en':'zh-Hans');
  assert.equal(await page.locator('#daily-table tr').count(),expectedDays);
  assert.equal(await page.locator('#composition-table tr').count(),4);
  const untranslated=await page.locator('[data-i18n]').evaluateAll(nodes=>nodes.filter(n=>n.textContent===n.dataset.i18n).map(n=>n.dataset.i18n));
  assert.deepEqual(untranslated,[]);
  if(language==='en')assert.deepEqual(await page.locator('[data-i18n],[data-bind],svg text,svg title').evaluateAll(nodes=>nodes.filter(n=>/[\u3400-\u9fff]/.test(n.textContent)).map(n=>n.textContent)),[]);
}
function totals(v,unpriced=0,cost=v/100){return {input:v/10,output:v/5,cacheRead:v*7/10,cacheWrite:0,cacheWrite1h:0,total:v,unpricedTokens:unpriced,cost};}
function fixture(values,{unpriced=false,long=false}={}){
  const days=values.map((v,i)=>({day:`2026-09-${String(i+1).padStart(2,'0')}`,recorded:v!==null,...totals(v??0,unpriced?(v??0):0,unpriced?0:(v??0)/100)}));
  const t=Object.fromEntries(Object.keys(totals(0)).map(key=>[key,days.reduce((n,d)=>n+d[key],0)]));
  const active=days.some(x=>x.recorded);
  const name=long?'provider/'+('long-model-name-'.repeat(12)):'fixture-model';
  return {period:'Fixture period',capturedAt:'2026-09-15T12:00:00Z',timezone:'Asia/Shanghai',totals:t,days,models:active?[{name,...t}]:[],sources:active?[{name:'Codex',...t}]:[],weekdays:[]};
}
try{
  await load();
  for(const language of ['zh','en']){
    await checkLanguage(language,snapshot.days.length);
    const metrics=await layout();
    assert(metrics.scrollWidth<=metrics.width+2,'Desktop overflow');
    assert.deepEqual(metrics.escapedLabels,[],'SVG labels escape the chart');
    assert.equal(Math.round(metrics.line.height),320,'Daily chart keeps its designed height');
    for(const slot of ['heading','chart','source'])assert(Math.abs(metrics.bounds[0][slot].y-metrics.bounds[1][slot].y)<=1,slot+' columns are not aligned');
    await page.locator('summary').focus();await page.keyboard.press('Enter');assert.equal(await page.locator('details').getAttribute('open'),'');
    await page.keyboard.press('Enter');assert.equal(await page.locator('details').getAttribute('open'),null);
    assert.equal(await page.locator('[data-chart][tabindex]').count(),0,'Decorative chart replay does not create unexplained keyboard stops');
    assert((await page.locator('#composition').getAttribute('aria-label')).includes(language==='en'?'New input':'新增输入'));
    await page.evaluate(()=>{document.activeElement?.blur();window.scrollTo(0,0);});
    await page.screenshot({path:join(output,'native-'+language+'.png'),fullPage:true});
    results.push({case:'native-'+language,...metrics});
  }
  await page.goto(pathToFileURL(reportFile).href);await page.locator('[data-language=zh]').click();await page.reload();
  assert.equal(await page.locator('html').getAttribute('lang'),'zh-Hans','Language choice persists for the exported file');
  for(const width of [640,390]){
    await page.setViewportSize({width,height:700});
    assert(await page.locator('.sheet').evaluate(n=>n.getBoundingClientRect().left>=0),'Narrow report loses its left edge');
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+2),'Narrow report body must reflow');
    await page.locator('[data-language=zh]').click();await page.locator('[data-language=en]').click();
    await page.screenshot({path:join(output,'native-'+width+'.png'),fullPage:true});
  }
  await page.setViewportSize({width:1280,height:960});
  const gap=fixture([0,100,null,50,0,200,150]);await load(gap);
  for(const lang of ['zh','en'])await checkLanguage(lang,7);
  const path=await page.locator('#daily path').getAttribute('d');
  assert.equal((path.match(/M/g)||[]).length,2,'Missing dates split the line into separate runs');
  assert.equal((path.match(/L/g)||[]).length,4,'Recorded zero days stay connected');
  await page.screenshot({path:join(output,'missing-and-zero-days.png'),fullPage:true});
  results.push({case:'seven-day-gap',path});

  await load(fixture(Array(30).fill(null)));
  assert.equal(await page.locator('[data-bind=cost]').first().textContent(),'No record');
  assert.equal(await page.locator('#daily path').count(),0);
  assert(await page.locator('[data-summary=daily-peak]').isHidden());
  results.push({case:'missing',passed:true});
  await load(fixture(Array(7).fill(0)));
  assert.equal(await page.locator('[data-bind=cost]').first().textContent(),'$0.00');
  assert.equal(await page.locator('#daily path').count(),1);
  assert(await page.locator('[data-summary=daily-peak]').isHidden());
  assert.equal(await page.locator('#daily text').filter({hasText:/^1$/}).count(),0,'Zero data does not show fabricated unit ticks');
  assert(!(await page.locator('body').innerText()).includes('NaN'));
  results.push({case:'recorded-zero',passed:true});
  const tiny=fixture([3,0,0,0,0,0,0]);
  for(const row of [tiny.totals,...tiny.days,...tiny.models,...tiny.sources]){row.input=row.total;row.output=0;row.cacheRead=0;}
  await load(tiny);
  assert.equal(await page.locator('#daily text').filter({hasText:/^1\.5$/}).count(),1,'Halfway tick preserves fractional values');
  results.push({case:'small-odd-peak',passed:true});
  await load(fixture(Array(7).fill(100),{unpriced:true}));
  assert.equal(await page.locator('[data-bind=cost]').first().textContent(),'Unpriced');
  assert(!(await page.locator('body').innerText()).includes('$0.00'));
  assert(await page.locator('[data-summary=model-cost]').isHidden());
  assert.equal(await page.evaluate(()=>Chart.getChart(document.querySelector('#models')).data.datasets[0].data.length),0);
  results.push({case:'all-unpriced',passed:true});
  await load(fixture(Array(7).fill(100),{long:true}));
  assert((await page.locator('#model-table th').first().textContent()).length>100);
  assert.equal((await layout()).escapedLabels.length,0);
  await page.screenshot({path:join(output,'long-model.png'),fullPage:true});
  results.push({case:'long-model',passed:true});
  const high=fixture(Array(7).fill(1e12));high.totals.cost=3e13;
  high.models=Array.from({length:3},(_,i)=>({name:'high-cost-'+i,...totals(high.totals.total/3,0,1e13)}));
  await load(high);
  assert((await page.locator('[data-bind=totalTokens]').first().textContent()).endsWith('T'));
  assert.deepEqual((await layout()).escapedLabels,[]);
  const labelWidths=await page.evaluate(()=>{
    const c=Chart.getChart(document.querySelector('#models')),ctx=c.ctx;ctx.font='700 11px Inter, Arial';
    return {label:ctx.measureText('$10.00T').width,gap:c.getDatasetMeta(0).data[1].x-c.getDatasetMeta(0).data[0].x};
  });
  assert(labelWidths.label+8<labelWidths.gap,'Large cost labels remain separated');
  await page.screenshot({path:join(output,'large-costs.png'),fullPage:true});results.push({case:'large-costs',...labelWidths});
  assert.deepEqual(errors,[]);assert.equal(external,0);
  writeFileSync(join(output,'verification.json'),JSON.stringify({results,errors,external},null,2)+'\n');
  console.log('Passed native report: bilingual layout, column alignment, labels, 320px trend, missing/zero dates, pricing states, keyboard, offline, narrow windows, and long model IDs.');
}finally{rmSync(reportFile,{force:true});await browser.close();}
