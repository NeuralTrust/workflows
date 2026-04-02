#!/usr/bin/env node
/**
 * Live SEO content checks: sitemap structure + URL sanity, robots Sitemap line,
 * per-page H1, canonical link, JSON-LD (valid JSON).
 *
 * Usage:
 *   node scripts/seo-live-content-audit.mjs --base-url https://example.com [options]
 *
 * Options:
 *   --max-url-checks N   HEAD/GET this many sitemap URLs (default 50, 0 = skip)
 *   --max-sitemap-depth  Nested sitemap index recursion depth (default 3)
 *   --paths /,/foo       Extra paths to audit like Lighthouse (comma-separated)
 *   --home-html PATH     Use this file as homepage HTML instead of fetching
 *   --strict             Exit 1 on any error-level finding
 */

import fs from 'fs'
import { URL } from 'url'

function parseArgs(argv) {
	const out = {
		baseUrl: '',
		maxUrlChecks: 50,
		maxSitemapDepth: 3,
		paths: '/',
		homeHtml: '',
		strict: false,
	}
	for (let i = 2; i < argv.length; i++) {
		const a = argv[i]
		if (a === '--strict') out.strict = true
		else if (a === '--base-url' && argv[i + 1]) out.baseUrl = argv[++i].replace(/\/$/, '')
		else if (a === '--max-url-checks' && argv[i + 1]) out.maxUrlChecks = parseInt(argv[++i], 10) || 0
		else if (a === '--max-sitemap-depth' && argv[i + 1]) out.maxSitemapDepth = parseInt(argv[++i], 10) || 2
		else if (a === '--paths' && argv[i + 1]) out.paths = argv[++i]
		else if (a === '--home-html' && argv[i + 1]) out.homeHtml = argv[++i]
	}
	return out
}

/** @typedef {{ level: 'error' | 'warn' | 'info', rule: string, message: string, fix?: string }} Row */
/** @type {Row[]} */
const rows = []

function add(level, rule, message, fix = '') {
	rows.push({ level, rule, message, fix })
}

const UA = { 'user-agent': 'NeuralTrust-SEO-Audit/1.0' }

async function fetchText(url, method = 'GET') {
	const controller = new AbortController()
	const t = setTimeout(() => controller.abort(), 30000)
	try {
		const r = await fetch(url, {
			method,
			signal: controller.signal,
			redirect: 'follow',
			headers: UA,
		})
		const text = await r.text()
		return { ok: r.ok, status: r.status, text, finalUrl: r.url }
	} finally {
		clearTimeout(t)
	}
}

function extractLocs(xml) {
	const locs = []
	const re = /<loc>\s*([\s\S]*?)<\/loc>/gi
	let m
	while ((m = re.exec(xml)) !== null) {
		let inner = m[1].replace(/<!\[CDATA\[/g, '').replace(/\]\]>/g, '').trim()
		inner = inner.replace(/\s+/g, '')
		if (inner) locs.push(inner)
	}
	return locs
}

function isLikelySitemapUrl(u) {
	try {
		const p = new URL(u).pathname
		return /\.xml(\?|$)/i.test(p) || /sitemap/i.test(p)
	} catch {
		return false
	}
}

/**
 * @param {string} xml
 * @returns {'index' | 'urlset'}
 */
function sitemapKind(xml) {
	if (/<sitemapindex[\s>]/i.test(xml)) return 'index'
	return 'urlset'
}

async function collectPageUrlsFromSitemap(sitemapUrl, depth, maxDepth, seenSitemaps, acc) {
	if (depth > maxDepth || seenSitemaps.has(sitemapUrl)) return
	seenSitemaps.add(sitemapUrl)
	const { ok, status, text } = await fetchText(sitemapUrl)
	if (!ok) {
		add('error', 'sitemap-fetch', `Could not fetch sitemap \`${sitemapUrl}\` (HTTP ${status}).`, 'Fix server routing and ensure sitemap returns 200.')
		return
	}
	const kind = sitemapKind(text)
	const locs = extractLocs(text)
	if (locs.length === 0) {
		add('warn', 'sitemap-empty', `Sitemap \`${sitemapUrl}\` has no \`<loc>\` entries.`, 'Ensure the generator outputs URLs; empty sitemaps hurt discovery.')
		return
	}
	if (kind === 'index') {
		for (const loc of locs) {
			if (isLikelySitemapUrl(loc)) await collectPageUrlsFromSitemap(loc, depth + 1, maxDepth, seenSitemaps, acc)
			else acc.push(loc)
		}
	} else {
		for (const loc of locs) acc.push(loc)
	}
}

function normalizeHost(host) {
	return host.replace(/^www\./, '').toLowerCase()
}

function validateUrlsAgainstBase(urls, baseOrigin) {
	let baseHost
	try {
		baseHost = normalizeHost(new URL(baseOrigin).hostname)
	} catch {
		add('error', 'base-url', 'Invalid --base-url', '')
		return
	}
	const bad = []
	for (const u of urls) {
		try {
			const parsed = new URL(u)
			if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') bad.push(`${u} (bad scheme)`)
			const h = normalizeHost(parsed.hostname)
			if (h !== baseHost && !h.endsWith(`.${baseHost}`)) bad.push(`${u} (host ≠ ${baseHost})`)
		} catch {
			bad.push(`${u} (invalid URL)`)
		}
	}
	if (bad.length) {
		add(
			'warn',
			'sitemap-url-host',
			`${bad.length} sitemap URL(s) look wrong (host/scheme): ${bad.slice(0, 5).join('; ')}${bad.length > 5 ? '…' : ''}`,
			'Use absolute https URLs on the production host; avoid staging domains in the live sitemap.'
		)
	}
}

async function checkUrlsReturnOk(urls, maxChecks) {
	if (maxChecks <= 0 || urls.length === 0) return
	const slice = [...new Set(urls)].slice(0, maxChecks)
	let failed = []
	for (const u of slice) {
		try {
			const r = await fetch(u, { method: 'HEAD', redirect: 'follow', headers: UA })
			let ok = r.ok
			if (r.status === 405 || r.status === 501) {
				const g = await fetchText(u, 'GET')
				ok = g.ok && g.status < 400
			}
			if (!ok) failed.push(`${u} → ${r.status}`)
		} catch (e) {
			failed.push(`${u} → ${e.message || 'fetch error'}`)
		}
		await new Promise((r) => setTimeout(r, 75))
	}
	if (failed.length) {
		add(
			'error',
			'sitemap-url-http',
			`${failed.length} URL(s) from sitemap failed HEAD/GET: ${failed.slice(0, 8).join('; ')}${failed.length > 8 ? '…' : ''}`,
			'Fix broken links; Google may drop or distrust the sitemap.'
		)
	}
}

function stripScripts(html) {
	return html
		.replace(/<script[\s\S]*?<\/script>/gi, '')
		.replace(/<style[\s\S]*?<\/style>/gi, '')
		.replace(/<!--[\s\S]*?-->/g, '')
}

function auditHtml(html, label) {
	const body = stripScripts(html)
	const h1Matches = body.match(/<h1\b[^>]*>/gi) || []
	const h1Count = h1Matches.length
	if (h1Count === 0) {
		add('warn', 'h1-missing', `**${label}**: no \`<h1>\` in HTML (after stripping scripts).`, 'Each important landing page should have exactly one visible H1.')
	} else if (h1Count > 1) {
		add('warn', 'h1-multiple', `**${label}**: ${h1Count} \`<h1>\` elements.`, 'Prefer a single H1 per page for clarity and SEO.')
	}

	const canon =
		body.match(/<link[^>]+rel=["']canonical["'][^>]*>/i) ||
		body.match(/<link[^>]+href=["'][^"']+["'][^>]*rel=["']canonical["']/i)
	if (!canon) {
		add('warn', 'canonical-missing', `**${label}**: no \`<link rel="canonical"\` found.`, 'Set canonical via Next.js `alternates.canonical` or a link tag to avoid duplicate-content issues.')
	}

	const ldRe = /<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi
	let m
	let ldCount = 0
	let ldInvalid = 0
	while ((m = ldRe.exec(body)) !== null) {
		ldCount++
		const raw = m[1].trim()
		if (!raw) {
			ldInvalid++
			continue
		}
		try {
			JSON.parse(raw)
		} catch {
			ldInvalid++
		}
	}
	if (ldCount === 0) {
		add('info', 'jsonld-missing', `**${label}**: no \`application/ld+json\` script blocks.`, 'Add JSON-LD (Organization, WebSite, Article…) for rich results where relevant.')
	} else if (ldInvalid > 0) {
		add('warn', 'jsonld-invalid', `**${label}**: ${ldInvalid} JSON-LD block(s) empty or invalid JSON.`, 'Fix syntax; invalid structured data can be ignored by Google.')
	}
}

function auditRobotsContent(text, baseOrigin) {
	let host
	try {
		host = normalizeHost(new URL(baseOrigin).hostname)
	} catch {
		return
	}
	const lines = text.split(/\r?\n/)
	const sitemapLines = lines.filter((l) => /^\s*Sitemap\s*:/i.test(l))
	if (sitemapLines.length === 0) {
		add('warn', 'robots-sitemap-line', '`robots.txt` has no `Sitemap:` line.', 'Add `Sitemap: https://your.domain/sitemap.xml` so crawlers find the sitemap.')
	} else {
		for (const line of sitemapLines) {
			const urlPart = line.replace(/^\s*Sitemap\s*:\s*/i, '').trim()
			try {
				const h = normalizeHost(new URL(urlPart).hostname)
				if (h !== host && !h.endsWith(`.${host}`)) {
					add('warn', 'robots-sitemap-host', `\`Sitemap:\` points to another host: \`${urlPart}\``, 'Align with production BASE_URL.')
				}
			} catch {
				add('warn', 'robots-sitemap-bad', `Invalid Sitemap URL in robots: \`${line}\``, '')
			}
		}
	}
	if (/Disallow\s*:\s*\/\s*$/im.test(text) && !/Allow\s*:\s*\//im.test(text)) {
		add('info', 'robots-disallow-root', '`robots.txt` may disallow entire site (`Disallow: /`).', 'Confirm this is intentional on production.')
	}
}

function printReport() {
	console.log('## SEO live content audit\n')
	console.log('| Level | Rule | Issue | Suggested fix |')
	console.log('|-------|------|-------|---------------|')
	for (const r of rows) {
		console.log(
			`| ${r.level} | ${r.rule} | ${r.message.replace(/\|/g, '\\|')} | ${(r.fix || '—').replace(/\|/g, '\\|')} |`
		)
	}
	const err = rows.filter((x) => x.level === 'error').length
	const warn = rows.filter((x) => x.level === 'warn').length
	const info = rows.filter((x) => x.level === 'info').length
	console.log('')
	console.log('### Summary\n')
	console.log(`- **Errors:** ${err}`)
	console.log(`- **Warnings:** ${warn}`)
	console.log(`- **Info:** ${info}`)
	return err
}

async function main() {
	const args = parseArgs(process.argv)
	if (!args.baseUrl) {
		console.error('Missing --base-url')
		process.exit(2)
	}

	const base = args.baseUrl
	let homeHtml = ''
	if (args.homeHtml && fs.existsSync(args.homeHtml)) {
		homeHtml = fs.readFileSync(args.homeHtml, 'utf8')
	} else {
		const home = await fetchText(`${base}/`)
		if (!home.ok) {
			add('error', 'homepage', `Homepage HTTP ${home.status}`, '')
		} else {
			homeHtml = home.text
		}
	}
	if (homeHtml) auditHtml(homeHtml, 'Homepage /')

	const extraPaths = args.paths
		.split(',')
		.map((s) => s.trim())
		.filter(Boolean)
	for (const p of extraPaths) {
		if (p === '/' || p === '') continue
		const pathPart = p.startsWith('/') ? p : `/${p}`
		const { ok, status, text } = await fetchText(base + pathPart)
		if (!ok) add('warn', 'path-fetch', `Could not fetch \`${pathPart}\` (HTTP ${status}).`, '')
		else auditHtml(text, pathPart)
	}

	// Sitemap
	const sitemapCandidates = [`${base}/sitemap.xml`, `${base}/sitemap_index.xml`]
	let foundSitemap = false
	const pageUrls = []
	const seen = new Set()
	for (const su of sitemapCandidates) {
		const { ok, status, text } = await fetchText(su)
		if (!ok) continue
		foundSitemap = true
		await collectPageUrlsFromSitemap(su, 0, args.maxSitemapDepth, seen, pageUrls)
		break
	}
	if (!foundSitemap) {
		add('warn', 'sitemap-missing', 'No sitemap at `/sitemap.xml` or `/sitemap_index.xml` (GET failed).', 'Ensure a sitemap is reachable for discovery.')
	} else {
		const unique = [...new Set(pageUrls)]
		add('info', 'sitemap-urls', `Collected **${unique.length}** unique page URL(s) from sitemap(s).`, '')
		if (unique.length === 0) {
			add('error', 'sitemap-no-pages', 'Sitemap(s) resolved but no page URLs collected.', 'Fix sitemap generation; empty index/urlset hurts SEO.')
		} else {
			validateUrlsAgainstBase(unique, base)
			await checkUrlsReturnOk(unique, args.maxUrlChecks)
		}
	}

	// robots.txt
	const robots = await fetchText(`${base}/robots.txt`)
	if (robots.ok && robots.text) {
		auditRobotsContent(robots.text, base)
	}

	const errCount = printReport()
	if (args.strict && errCount > 0) process.exit(1)
}

main().catch((e) => {
	console.error(e)
	process.exit(1)
})
