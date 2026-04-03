# Crawl4AI Benchmark Scripts

Crawl4AI benchmark scripts. Target: `https://the-internet.herokuapp.com`. Tests: `navigate`, `extract` only (no form/multi-step) — 3 runs each. See [`browser-benchmark-scripts.md`](browser-benchmark-scripts.md) for the full suite index.

## Sequential benchmark

```python
import asyncio, time, json
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig
from crawl4ai.extraction_strategy import JsonCssExtractionStrategy

BC = BrowserConfig(headless=True)

async def bench_navigate():
    async with AsyncWebCrawler(config=BC) as c:
        s = time.time()
        r = await c.arun(url="https://the-internet.herokuapp.com/", config=CrawlerRunConfig(screenshot=True))
        assert r.success, f"Failed: {r.error_message}"
        return f"{time.time() - s:.2f}"

async def bench_extract():
    schema = {"name": "TableRows", "baseSelector": "table tbody tr",
              "fields": [{"name": "text", "selector": "td:first-child", "type": "text"}]}
    async with AsyncWebCrawler(config=BC) as c:
        s = time.time()
        r = await c.arun(url="https://the-internet.herokuapp.com/challenging_dom",
            config=CrawlerRunConfig(extraction_strategy=JsonCssExtractionStrategy(schema)))
        assert r.success
        data = json.loads(r.extracted_content)
        assert len(data) >= 5, f"Expected 5+ rows, got {len(data)}"
        return f"{time.time() - s:.2f}"

async def run():
    results = {n: [await f() for _ in range(3)] for n, f in [("navigate", bench_navigate), ("extract", bench_extract)]}
    print(json.dumps(results, indent=2))

asyncio.run(run())
```

## Parallel benchmark

```python
import asyncio, time
from crawl4ai import AsyncWebCrawler, BrowserConfig, CrawlerRunConfig

URLS = ["https://the-internet.herokuapp.com/" + p for p in ["login", "checkboxes", "dropdown", "tables", "frames"]]

async def run():
    bc, rc = BrowserConfig(headless=True), CrawlerRunConfig(screenshot=True)
    s = time.time()
    async with AsyncWebCrawler(config=bc) as c:
        for u in URLS: await c.arun(url=u, config=rc)
    seq = time.time() - s
    s = time.time()
    async with AsyncWebCrawler(config=bc) as c:
        await c.arun_many(urls=URLS, config=rc)
    par = time.time() - s
    print(f"Sequential: {seq:.2f}s | Parallel: {par:.2f}s | Speedup: {seq/par:.1f}x")

asyncio.run(run())
```
