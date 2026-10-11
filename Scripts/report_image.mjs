// Renders a synthetic native HTML report for the README. Takes input HTML and output PNG paths.
import {realpathSync,mkdirSync} from 'node:fs';
import {dirname,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';

const [input,output]=process.argv.slice(2);
if(!input||!output)throw new Error('Usage: node Scripts/report_image.mjs INPUT.html OUTPUT.png');
const modulePath=process.env.PLAYWRIGHT_MODULE||realpathSync(execFileSync('which',['playwright-cli'],{encoding:'utf8'}).trim());
const {chromium}=createRequire(modulePath)('playwright');
const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH||'/Applications/Brave Browser.app/Contents/MacOS/Brave Browser'});
try{
  const context=await browser.newContext({viewport:{width:1040,height:1000},reducedMotion:'reduce'});
  const errors=[];
  await context.route(/^https?:/,route=>{errors.push('Unexpected external resource: '+route.request().url());return route.abort();});
  const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));
  await page.goto(pathToFileURL(resolve(input)).href+'?lang=en');
  await page.waitForFunction(()=>typeof window.setReportLanguage==='function');
  await page.locator('[data-language=en]').click();
  if(errors.length)throw new Error(errors.join('\n'));
  mkdirSync(dirname(resolve(output)),{recursive:true});
  await page.screenshot({path:resolve(output),fullPage:true});
  console.log('Rendered sample report: '+output);
}finally{await browser.close();}
