#!/usr/bin/env node
/**
 * Static SEO audit for Next.js (App Router) and similar layouts.
 * Prints findings and actionable suggestions to stdout (Markdown).
 *
 * Usage:
 *   node scripts/seo-static-audit.mjs --cwd /path/to/repo [--roots app,src/app] [--strict]
 *
 * --strict  Exit 1 if any error-level finding (warnings alone do not fail).
 */

import fs from 'fs'
import path from 'path'

function parseArgs(argv) {
	const out = { cwd: '.', roots: null, strict: false }
	for (let i = 2; i < argv.length; i++) {
		const a = argv[i]
		if (a === '--strict') out.strict = true
		else if (a === '--cwd' && argv[i + 1]) {
			out.cwd = argv[++i]
		} else if (a === '--roots' && argv[i + 1]) {
			out.roots = argv[++i]
		}
	}
	return out
}

const SKIP_DIRS = new Set([
	'node_modules',
	'.next',
	'dist',
	'build',
	'.git',
	'coverage',
	'__tests__',
	'tests',
	'e2e',
	'.turbo',
])

/** @typedef {{ level: 'error' | 'warn' | 'info', file?: string, rule: string, message: string, fix: string }} Finding */

/** @type {Finding[]} */
const findings = []

function add(level, rule, message, fix, file) {
	findings.push({ level, rule, message, fix, file })
}

function walkFiles(dir, acc = []) {
	if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return acc
	for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
		const p = path.join(dir, ent.name)
		if (ent.isDirectory()) {
			if (SKIP_DIRS.has(ent.name)) continue
			walkFiles(p, acc)
		} else {
			const ext = path.extname(ent.name).toLowerCase()
			if (['.tsx', '.ts', '.jsx', '.js', '.mjs'].includes(ext)) acc.push(p)
		}
	}
	return acc
}

function read(p) {
	try {
		return fs.readFileSync(p, 'utf8')
	} catch {
		return ''
	}
}

function isPageFile(name) {
	return /^page\.(tsx|ts|jsx|js)$/.test(name)
}

function isLayoutFile(name) {
	return /^layout\.(tsx|ts|jsx|js)$/.test(name)
}

function isApiRoute(filePath) {
	return filePath.includes(`${path.sep}api${path.sep}`) || filePath.includes('/api/')
}

function hasMetadataExport(content) {
	return (
		/\bexport\s+(const|async\s+function)\s+metadata\b/.test(content) ||
		/\bexport\s+async\s+function\s+generateMetadata\b/.test(content)
	)
}

function metadataHasStaticTitle(content) {
	if (/\bgenerateMetadata\b/.test(content)) return true
	return /\btitle\s*:/.test(content)
}

function metadataHasStaticDescription(content) {
	if (/\bgenerateMetadata\b/.test(content)) return true
	return /\bdescription\s*:/.test(content)
}

function hasOpenGraph(content) {
	return /\bopenGraph\s*:/.test(content) || /\bopengraph\s*:/i.test(content)
}

function hasTwitter(content) {
	return /\btwitter\s*:/.test(content)
}

function hasMetadataBase(content) {
	return /\bmetadataBase\s*:/.test(content)
}

function relPosix(projectRoot, filePath) {
	return path.relative(projectRoot, filePath).split(path.sep).join('/')
}

function findRootLayoutFiles(files, projectRoot) {
	const roots = []
	const rels = new Set()
	for (const f of files) {
		const base = path.basename(f)
		if (!isLayoutFile(base)) continue
		const rel = relPosix(projectRoot, f)
		if (/(^|\/)app\/layout\.(tsx|ts|jsx|js)$/.test(rel) || /(^|\/)src\/app\/layout\.(tsx|ts|jsx|js)$/.test(rel)) {
			roots.push(f)
			rels.add(rel)
		}
	}
	if (roots.length > 0) return roots
	// Next.js apps with no app/layout.* — common pattern: app/[locale]/layout.tsx only
	for (const f of files) {
		const base = path.basename(f)
		if (!isLayoutFile(base)) continue
		const rel = relPosix(projectRoot, f)
		if (/^app\/[^/]+\/layout\.(tsx|ts|jsx|js)$/.test(rel) || /^src\/app\/[^/]+\/layout\.(tsx|ts|jsx|js)$/.test(rel)) {
			roots.push(f)
		}
	}
	return roots
}

function findSitemap(files, projectRoot) {
	return files.filter((f) => {
		const rel = relPosix(projectRoot, f)
		return /(^|\/)sitemap\.(ts|tsx|js|jsx)$/.test(rel) || /sitemap\.xml\/route\.(ts|tsx|js|jsx)$/.test(rel)
	})
}

function findRobots(files, projectRoot) {
	return files.filter((f) => {
		const rel = relPosix(projectRoot, f)
		return /(^|\/)robots\.(ts|tsx|js|jsx)$/.test(rel) || /robots\.txt\/route\.(ts|tsx|js|jsx)$/.test(rel)
	})
}

function countH1TagsInSource(content) {
	const m = content.match(/<h1\b/gi)
	return m ? m.length : 0
}

function hasCanonicalInSource(content) {
	return (
		(/\balternates\s*:/.test(content) && /\bcanonical\s*:/.test(content)) ||
		/<link[^>]+rel=['"]canonical['"]/i.test(content)
	)
}

function hasJsonLdInSource(content) {
	return (
		/application\/ld\+json/i.test(content) ||
		/['"]application\/ld\+json['"]/.test(content)
	)
}

function auditImageAlts(content, file) {
	const lines = content.split('\n')
	lines.forEach((line, idx) => {
		if (!/<Image\b/.test(line) && !/<img\b/i.test(line)) return
		if (/\/\*[\s\S]*?\*\//.test(line)) return
		if (/<Image[^>]*\salt\s*=\s*["'{]/i.test(line) || /<img[^>]*\salt\s*=/i.test(line)) return
		if (/<Image[^>]*\salt\s*=\s*\{/i.test(line)) return
		// Decorative-only heuristic: empty alt is valid; flag only missing alt prop
		if (/<Image\b/.test(line)) {
			add(
				'warn',
				'image-alt',
				`Possible Next.js <Image> without alt (line ${idx + 1}).`,
				'Add a concise `alt` describing the image, or `alt=""` if purely decorative.',
				file
			)
		}
	})
}

function runAudit(projectRoot, rootDirs) {
	const allFiles = []
	for (const rd of rootDirs) {
		const abs = path.join(projectRoot, rd)
		walkFiles(abs, allFiles)
	}

	if (allFiles.length === 0) {
		add('warn', 'no-files', `No source files found under roots: ${rootDirs.join(', ')}`, 'Set --roots to your App Router directory (e.g. `app` or `src/app`).')
		return
	}

	const rootLayouts = findRootLayoutFiles(allFiles, projectRoot)
	if (rootLayouts.length === 0) {
		add(
			'error',
			'root-layout',
			'No root `app/layout` or `src/app/layout` found.',
			'Ensure the App Router root layout exists so global metadata and `<html lang>` can be defined.'
		)
	} else {
		for (const lf of rootLayouts) {
			const c = read(lf)
			if (!hasMetadataExport(c)) {
				add(
					'error',
					'layout-metadata',
					'Root layout does not export `metadata` or `generateMetadata`.',
					'Export `metadata` or `generateMetadata` from the root layout for default title, description, and robots.',
					lf
				)
			} else {
				if (!metadataHasStaticTitle(c)) {
					add(
						'warn',
						'title',
						'Root metadata may be missing an explicit `title`.',
						'Set `metadata.title` or return `title` from `generateMetadata` for SERP titles.',
						lf
					)
				}
				if (!metadataHasStaticDescription(c)) {
					add(
						'warn',
						'description',
						'Root metadata may be missing `description`.',
						'Add `metadata.description` (≈150–160 chars) for search snippets.',
						lf
					)
				}
				if (hasOpenGraph(c) && !hasMetadataBase(c)) {
					add(
						'warn',
						'metadata-base',
						'`openGraph` is present but `metadataBase` may be missing.',
						'Set `metadataBase: new URL("https://your-domain.com")` in root metadata so OG URLs resolve to absolute links.',
						lf
					)
				}
				if (!hasOpenGraph(c)) {
					add(
						'info',
						'open-graph',
						'No `openGraph` block detected in root layout metadata.',
						'Consider `openGraph.title`, `description`, `url`, and `images` for link previews.',
						lf
					)
				}
				if (!hasTwitter(c)) {
					add(
						'info',
						'twitter-card',
						'No `twitter` metadata block detected.',
						'Optional: add `twitter.card`, `title`, `description`, and `images` for X/Twitter previews.',
						lf
					)
				}
			}
			if (!/\blang\s*=/.test(c)) {
				add(
					'warn',
					'html-lang',
					'Root layout `<html>` may be missing `lang`.',
					'Use `<html lang="en">` (or dynamic locale) for accessibility and SEO.',
					lf
				)
			}
		}
	}

	const sitemaps = findSitemap(allFiles, projectRoot)
	if (sitemaps.length === 0) {
		add(
			'info',
			'sitemap',
			'No `sitemap.ts` / `sitemap.js` (or sitemap route) found under app roots.',
			'Add a sitemap so crawlers discover URLs (see Next.js Metadata `sitemap` export).'
		)
	}

	const robots = findRobots(allFiles, projectRoot)
	if (robots.length === 0) {
		add(
			'info',
			'robots',
			'No `robots.ts` / `robots.txt` route found under app roots.',
			'Add `app/robots.ts` or `robots.txt` route to control crawling rules.'
		)
	}

	// Page-level: metadata nudge, images, H1 / canonical / JSON-LD hints
	for (const f of allFiles) {
		if (!isPageFile(path.basename(f)) || isApiRoute(f)) continue
		const c = read(f)
		if (/^['"]use client['"]/m.test(c.trimStart())) continue
		const rel = relPosix(projectRoot, f)
		const depth = rel.split('/').length
		if (!hasMetadataExport(c) && depth <= 4) {
			add(
				'info',
				'page-metadata',
				`Page has no exported \`metadata\` / \`generateMetadata\` (may inherit from layouts).`,
				'If this URL needs a unique title/description for SERPs, add `generateMetadata` or a segment `layout.tsx` with metadata.',
				f
			)
		}
		auditImageAlts(c, f)

		// Catch-all routes (e.g. [...slug]) often render H1/JSON-LD from CMS — skip noisy static rules
		if (/\[\.\.\.[^\]]+\]/.test(rel)) continue

		// H1 / canonical / JSON-LD hints on route pages (static source)
		const h1n = countH1TagsInSource(c)
		if (h1n === 0) {
			add(
				'warn',
				'page-h1',
				'No `<h1` in this page source (may be injected by MDX/CMS).',
				'Ensure the rendered page has exactly one visible H1 for SEO.',
				f
			)
		} else if (h1n > 1) {
			add(
				'warn',
				'page-h1-multiple',
				`Multiple (\`${h1n}\`) \`<h1>\` in source — usually prefer one per page.`,
				'Consolidate to a single H1 or move secondary headings to h2.',
				f
			)
		}
		if (!hasCanonicalInSource(c) && !/\bgenerateMetadata\b/.test(c)) {
			add(
				'info',
				'page-canonical',
				'No `alternates.canonical` / `<link rel="canonical">` in this file (may inherit from layout).',
				'Set explicit canonicals on indexable URLs to avoid duplicate content.',
				f
			)
		}
		if (!hasJsonLdInSource(c)) {
			add(
				'info',
				'page-jsonld',
				'No `application/ld+json` script in this file.',
				'Add JSON-LD where you need rich results (Organization, WebSite, Article, FAQ…).',
				f
			)
		}
	}

	// Top-level locale segment layout only (avoid noise on every nested dashboard layout)
	for (const f of allFiles) {
		if (!isLayoutFile(path.basename(f))) continue
		if (rootLayouts.includes(f)) continue
		const rel = relPosix(projectRoot, f)
		const isLocaleRoot =
			/^app\/\[locale\]\/layout\.(tsx|ts|jsx|js)$/.test(rel) ||
			/^src\/app\/\[locale\]\/layout\.(tsx|ts|jsx|js)$/.test(rel)
		if (!isLocaleRoot) continue
		const c = read(f)
		if (hasMetadataExport(c)) continue
		add(
			'info',
			'locale-layout',
			'Locale root layout has no `metadata` / `generateMetadata`.',
			'Add localized `generateMetadata` for `title`, `description`, and `alternates.languages`.',
			f
		)
	}
}

function printReport(projectName, projectRoot) {
	const byLevel = { error: [], warn: [], info: [] }
	for (const f of findings) {
		byLevel[f.level].push(f)
	}

	console.log(`## SEO static audit${projectName ? `: ${projectName}` : ''}\n`)
	console.log(`| Level | Rule | Location | Issue | Suggested fix |`)
	console.log(`|-------|------|----------|-------|---------------|`)
	for (const f of findings) {
		let loc = '—'
		if (f.file) {
			const rel = relPosix(projectRoot, f.file)
			loc = rel && !rel.startsWith('..') ? `\`${rel}\`` : `\`${f.file}\``
		}
		console.log(`| ${f.level} | ${f.rule} | ${loc} | ${f.message.replace(/\|/g, '\\|')} | ${f.fix.replace(/\|/g, '\\|')} |`)
	}
	console.log('')
	console.log('### Summary\n')
	console.log(`- **Errors:** ${byLevel.error.length}`)
	console.log(`- **Warnings:** ${byLevel.warn.length}`)
	console.log(`- **Info:** ${byLevel.info.length}`)
}

const { cwd, roots: rootsArg, strict } = parseArgs(process.argv)
const projectRoot = path.resolve(cwd)
const defaultRoots = ['app', 'src/app', 'pages']
let rootDirs = rootsArg
	? rootsArg.split(',').map((s) => s.trim()).filter(Boolean)
	: defaultRoots

rootDirs = rootDirs.filter((r) => fs.existsSync(path.join(projectRoot, r)))
if (!rootsArg && rootDirs.length === 0) {
	rootDirs = defaultRoots.filter((r) => fs.existsSync(path.join(projectRoot, r)))
}

if (rootDirs.length === 0) {
	console.error('No valid --roots directories found under', projectRoot)
	process.exit(2)
}

runAudit(projectRoot, rootDirs)
printReport(process.env.SEO_PROJECT_NAME || '', projectRoot)

const errCount = findings.filter((f) => f.level === 'error').length
if (strict && errCount > 0) {
	console.error(`\nStrict mode: ${errCount} error-level finding(s).`)
	process.exit(1)
}
