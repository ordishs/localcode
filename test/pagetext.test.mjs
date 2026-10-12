import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import test from "node:test";
import { Worker, isMainThread, parentPort, workerData } from "node:worker_threads";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.startsWith("@earendil-works/")) {
      return {
        url: "data:text/javascript,export const Type = {}; export const defineTool = (tool) => tool;",
        shortCircuit: true,
      };
    }
    const resolved = nextResolve(specifier, context);
    return resolved.url.endsWith(".ts") ? { ...resolved, format: "module-typescript" } : resolved;
  },
});

const { pageText } = await import("../extensions/exa.ts");

const HTML = "text/html; charset=utf-8";
const CAP = 2_000_000;
const LIMIT_MS = 1_000;
const KILL_MS = 10_000;

function fill(unit, head = "", tail = "") {
  return head + unit.repeat(Math.floor((CAP - head.length - tail.length) / unit.length)) + tail;
}

const ADVERSARIAL = {
  "'<' repeated, no '>'": () => fill("<"),
  "'<script ' repeated, no '>'": () => fill("<script "),
  "'<!--' repeated, no '-->'": () => fill("<!--"),
  "unterminated '<script>' repeated": () => fill("<script>"),
  "unterminated '<script>' with near-miss closers": () => fill("</script ", "<script>"),
  "unterminated '<!--' then '<!-' repeated": () => fill("<!-", "<!--"),
  "one tag of 2 MB": () => fill("<", "", ">"),
  "many '<script >' and one closer": () => fill("<script >", "", "</script>"),
  "'<>' repeated": () => fill("<>"),
};

function legacyPageText(body, contentType) {
  if (!contentType.includes("html")) return body;
  return body
    .replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, "")
    .replace(/<!--[^]*?-->/g, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&amp;/gi, "&")
    .replace(/[ \t]+/g, " ");
}

const SAMPLES = [
  `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Release notes &amp; downloads</title>
  <style>body { font: 14px/1.4 sans-serif; } a > b { color: red; }</style>
  <script type="application/ld+json">{"@type": "Article", "name": "<b>x</b>"}</script>
  <!--[if lt IE 9]><script src="html5shiv.js"></script><![endif]-->
</head>
<body>
  <nav><a href="/">Home</a> | <a href="/docs?a=1&amp;b=2">Docs</a></nav>
  <h1>Version 1.2&nbsp;released</h1>
  <p>Use <code>&lt;div&gt;</code> and &quot;quotes&quot; and &#39;apostrophes&#39;.</p>
  <pre>	tab	indented
    four spaces</pre>
  <SCRIPT>var s = "</div>"; if (a < b && c > d) {}</SCRIPT >
  <img src="x.png" alt="a>b"><br/><br />
  <p>Literal &amp;lt;tag&amp;gt; stays encoded once.</p>
  <!-- a comment with <p>markup</p> -->
  <footer>&copy; 2026 &NBSP; Example</footer>
</body>
</html>`,
  `<div class="post"><h2>Title</h2>\n<p>First line<br>second line</p>\n<ul><li>one</li><li>two</li></ul></div>`,
  `<p>a < b and c > d</p><p>x <> y</p><p><<b>bold</b></p>`,
  `<style media="print">\n.x{}\n</style\n><script async src="a.js"></script>` +
    `<script>document.write("<script><\\/script>")</script><p>after</p>`,
  `<p>Stuff</p><!----><!-- x --><p>more</p><!-- <script src="old.js"></script> --><p>tail</p>`,
  `<scripts>not a block</scripts><script-x>is a block</script><p>after</p>`,
  `<table>\n\t<tr><td>1</td>\t<td>2</td></tr>\n</table> <p>nbsp</p>`,
];

function seeded(seed) {
  return () => {
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const TOKENS = [
  "<", ">", "<>", "</", "/", "!", "-", "--", "<!-", "<!--", "-->", "->",
  "<script", "<SCRIPT", "<Style", "<style", "script", "</script", "</SCRIPT", "</STYLE", "</style\n>",
  "</script >", "</script x>", "<scripts>", "<script-x>", "<p>", "</p>",
  " ", "\t", "\n", " ", " ", "a", "b c", "=", '"', "'",
  "&amp;", "&lt;", "&gt;", "&nbsp;", "&NBSP;", "&quot;", "&#39;", "&amp;lt;",
];

const CLOSE_ALL = "></script></style> -->>";

if (isMainThread) {
  function timeInWorker(name) {
    return new Promise((resolve, reject) => {
      const worker = new Worker(new URL(import.meta.url), { workerData: name });
      const timer = setTimeout(() => {
        worker.terminate();
        reject(new Error(`pageText still ran after ${KILL_MS} ms`));
      }, KILL_MS);
      worker.once("message", (ms) => {
        clearTimeout(timer);
        resolve(ms);
      });
      worker.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
      worker.once("exit", (code) => {
        clearTimeout(timer);
        reject(new Error(`worker exited with code ${code}`));
      });
    });
  }

  for (const name of Object.keys(ADVERSARIAL)) {
    test(`2 MB adversarial input in under ${LIMIT_MS} ms: ${name}`, async (t) => {
      const ms = await timeInWorker(name);
      t.diagnostic(`${ms.toFixed(1)} ms`);
      assert.ok(ms < LIMIT_MS, `took ${ms.toFixed(1)} ms`);
    });
  }

  test("ordinary HTML gives the same text as the old regexes", () => {
    for (const sample of SAMPLES) {
      assert.equal(pageText(sample, HTML), legacyPageText(sample, HTML));
    }
  });

  test("closed token soup gives the same text as the old regexes", () => {
    const random = seeded(20261012);
    for (let i = 0; i < 3000; i++) {
      let input = "";
      const count = 1 + Math.floor(random() * 40);
      for (let j = 0; j < count; j++) input += TOKENS[Math.floor(random() * TOKENS.length)];
      input += CLOSE_ALL;
      assert.equal(pageText(input, HTML), legacyPageText(input, HTML), JSON.stringify(input));
    }
  });

  test("an unterminated block, comment, or tag drops the rest of the page", () => {
    assert.equal(pageText("a<script>b</style>c", HTML), "a");
    assert.equal(pageText("a<style x>b", HTML), "a");
    assert.equal(pageText("a<script", HTML), "a");
    assert.equal(pageText("a<script>b</script>c<style>d", HTML), "ac");
    assert.equal(pageText("a<!--b", HTML), "a");
    assert.equal(pageText("a<!-->b", HTML), "a");
    assert.equal(pageText("a<p>b<c", HTML), "a b");
    assert.equal(pageText("a<!-- <script> -->b<script>c</script>d", HTML), "a");
  });

  test("text that is not HTML passes through", () => {
    const body = "<p>a</p> &amp;\t\tb";
    assert.equal(pageText(body, "text/plain"), body);
  });
} else {
  const input = ADVERSARIAL[workerData]();
  const start = performance.now();
  pageText(input, HTML);
  parentPort.postMessage(performance.now() - start);
}
