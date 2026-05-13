// apply-probe-fix.cjs
// Patches .vite/build/index.js to simplify gateway health probe.
// Instead of sending model-specific Anthropic API requests,
// just checks endpoint reachability with a simple GET.
//
// Usage: node apply-probe-fix.cjs <path-to-extracted-asar-dir>
//
// This script works by finding the probeInference method's URL
// construction and fetch logic, then replacing them. Because the
// code is minified (variable names change per build), the patterns
// use structural matching against stable string literals.
//
// If this script fails on a new version, the error message includes
// manual remediation steps.

const fs = require('fs');
const path = require('path');

const TARGET = process.argv[2];
if (!TARGET) {
    console.error('Usage: node apply-probe-fix.cjs <path-to-extracted-asar-dir>');
    process.exit(1);
}

const indexPath = path.join(TARGET, '.vite/build/index.js');
if (!fs.existsSync(indexPath)) {
    console.error('File not found:', indexPath);
    console.error('Extract app.asar first: npx asar extract app.asar <dir>');
    process.exit(1);
}

let code = fs.readFileSync(indexPath, 'utf8');
let changes = 0;

// ── Pre-check: already patched? ────────────────────────────────────
// Patched code returns immediately from try block (no error formatting)
if (/return\{ok:!\d,latencyMs:Date\.now\(\)-\w+\}\}catch/.test(code)) {
    console.log('✓ Probe fix already applied.');
    process.exit(0);
}

// ── Step 1: Simplify URL construction ──────────────────────────────
// Match: ,URLVAR=CONDVAR?`${BASEURL}/v1/messages`:`${BASEURL}/v1/models?limit=1`
// Replace with: ,URLVAR=`${BASEURL}`
//
// Anchors: literal strings "/v1/messages" and "/v1/models?limit=1"
// which are unique to the probe URL construction.
//
// Note: use \x60 for backtick, \x24 for $, \x7B for {, \x7D for }
// to avoid shell escaping issues when testing with node -e.

const B  = '\x60';  // backtick
const D  = '\x24';  // dollar sign
const L  = '\x7B';  // left brace
const R  = '\x7D';  // right brace

const urlRegex = new RegExp(
    ','
    + '(\\w+)'                                // 1: urlVar
    + '=\\w+\\?'
    + B + '\\' + D + L + '(\\w+)' + R        // 2: baseUrlVar
    + '\\/v1\\/messages' + B
    + ':'
    + B + '\\' + D + L + '\\2' + R
    + '\\/v1\\/models\\?limit=1' + B
);

const urlMatch = code.match(urlRegex);
if (!urlMatch) {
    console.error('✗ Could not find URL construction pattern.');
    console.error('  Search for "v1/messages" near "v1/models?limit=1" in the file.');
    console.error('  If the pattern structure changed, update this script.');
    console.error('  If NOT found, the probe code may have been restructured entirely.');
    process.exit(1);
}

const urlVar    = urlMatch[1];
const baseUrlVar = urlMatch[2];
const oldUrl    = urlMatch[0];
const newUrl    = ',' + urlVar + '=' + B + D + L + baseUrlVar + R + B;

code = code.replace(oldUrl, newUrl);
changes++;
console.log('Step 1: URL simplified → just base URL (no /v1/... path)');

// ── Step 2: Simplify fetch + response handling ─────────────────────
// Match the try-catch block using the unique end anchor:
//   }catch(ERRVAR){return ERRFUNC(ERRVAR,"Gateway"
// This pattern (ObA(E,"Gateway") is unique to the probe's catch block.

const fullRegex = /,(\w+)=Date\.now\(\);try\{(.*?)\}catch\((\w+)\)\{return (\w+)\(\3,"Gateway"/;
const fullMatch = code.match(fullRegex);

if (!fullMatch) {
    console.error('✗ Step 2 failed: try-catch block not found.');
    console.error('  URL was fixed but fetch replacement needs manual work.');
    console.error('  In probeInference(), find the try{...}catch(E){return ObA(E,"Gateway"...}');
    console.error('  block and replace the fetch+response with:');
    console.error('    try{const E=await gA.net.fetch(c,{headers:g,redirect:"error",signal:AbortSignal.timeout(s)});return{ok:!0,latencyMs:Date.now()-I}}');
    console.error('  (adjust variable names to match the build)');
    process.exit(1);
}

const timer   = fullMatch[1];  // e.g. "I"
const fetchBody = fullMatch[2];
const errVar  = fullMatch[3];  // e.g. "E"
const errFunc = fullMatch[4];  // e.g. "ObA"

// Extract remaining variable names from the captured fetch body
// Pattern: const RESULT=COND?await NS.net.fetch(URL,{method:"POST",headers:{...HEADERS,...
const fetchVars = fetchBody.match(
    /const (\w+)=(\w+)\?await (\w+)\.net\.fetch\((\w+),\{method:"POST",headers:\{\.\.\.(\w+),/
);

if (!fetchVars) {
    console.error('✗ Step 2 failed: cannot parse fetch variable names.');
    console.error('  Manual fix needed. See instructions above.');
    process.exit(1);
}

const result  = fetchVars[1];   // e.g. "E"
const cond    = fetchVars[2];   // e.g. "i"
const ns      = fetchVars[3];   // e.g. "gA"
const url     = fetchVars[4];   // e.g. "c" (should match urlVar)
const headers = fetchVars[5];   // e.g. "g"

// Extract timeout var from: signal:AbortSignal.timeout(TIMEOUT)})
const timeoutMatch = fetchBody.match(/signal:AbortSignal\.timeout\((\w+)\)\}\)/);
if (!timeoutMatch) {
    console.error('✗ Step 2 failed: cannot find timeout variable.');
    process.exit(1);
}
const timeout = timeoutMatch[1];  // e.g. "s"

console.log('Step 2: timer=' + timer + ' result=' + result + ' ns=' + ns +
    ' url=' + url + ' headers=' + headers + ' timeout=' + timeout + ' err=' + errVar);

// Build replacement: simple GET, any HTTP response = success
// Preserve the catch block for network-level errors
const newFetch =
    ',' + timer + '=Date.now();try{' +
    'const ' + result + '=await ' + ns + '.net.fetch(' + url +
    ',{headers:' + headers + ',redirect:"error",signal:AbortSignal.timeout(' + timeout + ')});' +
    'return{ok:!0,latencyMs:Date.now()-' + timer + '}' +
    '}catch(' + errVar + '){return ' + errFunc + '(' + errVar + ',"Gateway"';

code = code.replace(fullMatch[0], newFetch);
changes++;
console.log('Step 2: Fetch simplified (GET base URL, any HTTP response = success)');

// ── Write back ─────────────────────────────────────────────────────
fs.writeFileSync(indexPath, code);
console.log('\nApplied ' + changes + ' changes to index.js');

// ── Verify ─────────────────────────────────────────────────────────
code = fs.readFileSync(indexPath, 'utf8');
if (/return\{ok:!\d,latencyMs:Date\.now\(\)-\w+\}\}catch/.test(code)) {
    console.log('Verification: PASSED - probe fix is active.');
} else {
    console.error('✗ Verification FAILED! Restore from backup and patch manually.');
    process.exit(1);
}
