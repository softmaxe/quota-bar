// Renders a synthetic native HTML report for the README. Takes input HTML and output PNG paths.
import {mkdirSync,writeFileSync} from 'node:fs';
import {dirname,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {captureReport,launchReportBrowser} from './report_browser.mjs';

const [input,output]=process.argv.slice(2);
if(!input||!output)throw new Error('Usage: node Scripts/report_image.mjs INPUT.html OUTPUT.png');
const browser=await launchReportBrowser();
try{
  const context=await browser.newContext({viewport:{width:1040,height:1000},reducedMotion:'reduce',colorScheme:'dark'});
  const errors=[];
  await context.route(/^https?:/,route=>{errors.push('Unexpected external resource: '+route.request().url());return route.abort();});
  const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));
  await page.goto(pathToFileURL(resolve(input)).href+'?lang=en');
  await page.locator('.hero-value').waitFor();
  const image=await captureReport(page);
  if(errors.length)throw new Error(errors.join('\n'));
  mkdirSync(dirname(resolve(output)),{recursive:true});
  writeFileSync(output,image);
  console.log('Rendered sample report: '+output);
}finally{await browser.close();}
