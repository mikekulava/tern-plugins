// Shared by the vitest and jest reporters: the event file, error and stack shaping.
// Events are JSON lines appended to $TESTVIEW_OUT, the format testview_py.py writes too.
'use strict'

const fs = require('node:fs')
const path = require('node:path')

const CONTEXT = 4
const MAX_TEXT = 64 * 1024

function emitter() {
	const out = process.env.TESTVIEW_OUT
	return (ev, fields) => {
		if (!out) return
		fs.appendFileSync(out, JSON.stringify({ ...fields, ev }) + '\n')
	}
}

function clip(text, limit = MAX_TEXT) {
	if (typeof text !== 'string') return text
	return text.length > limit ? `${text.slice(0, limit)}\n… [${text.length - limit} characters cut]` : text
}

const ANSI = /\u001b\[[0-9;]*[A-Za-z]/g
function plain(text) {
	return typeof text === 'string' ? text.replace(ANSI, '') : text
}

function filePath(file) {
	if (!file) return file
	if (file.startsWith('file://')) {
		try {
			return decodeURIComponent(new URL(file).pathname)
		} catch {
			return file.slice('file://'.length)
		}
	}
	return file
}

const sources = new Map()
function excerpt(file, line) {
	let lines = sources.get(file)
	if (lines === undefined) {
		try {
			const stat = fs.statSync(file)
			lines = stat.isFile() && stat.size < 2 * 1024 * 1024 ? fs.readFileSync(file, 'utf8').split(/\r?\n/) : null
		} catch {
			lines = null
		}
		sources.set(file, lines)
	}
	if (!lines || !line) return undefined
	const start = Math.max(1, line - CONTEXT)
	const end = Math.min(lines.length, line + CONTEXT)
	return { start, lines: lines.slice(start - 1, end) }
}

function isApp(file, root) {
	if (!file || !path.isAbsolute(file)) return false
	if (file.includes(`${path.sep}node_modules${path.sep}`)) return false
	const rel = path.relative(root, file)
	return !rel.startsWith('..') && !path.isAbsolute(rel)
}

function frame(fn, file, line, col, root) {
	file = filePath(file)
	const app = isApp(file, root)
	const f = { fn: fn || '', file, line, col, app }
	if (app) f.code = excerpt(file, line)
	return f
}

// V8 stack lines: `at fn (file:line:col)`, `at file:line:col`, `at async fn (…)`.
const AT = /^\s*at (?:async )?(?:(.*?) \()?(.+?):(\d+):(\d+)\)?\s*$/
function framesOfStack(stack, root) {
	const frames = []
	for (const raw of String(stack || '').split('\n')) {
		const m = AT.exec(raw)
		if (!m) continue
		const file = m[2]
		if (file.startsWith('node:') || file === '<anonymous>' || file.startsWith('internal/')) continue
		frames.push(frame(m[1], file, Number(m[3]), Number(m[4]), root))
	}
	return frames
}

// An error from either runner: { name, message, stack, diff, stacks } (stacks: vitest's parsed,
// source-mapped frames {method, file, line, column}).
function errorOf(err, root, text) {
	if (!err || typeof err !== 'object') {
		const s = plain(String(err ?? ''))
		return { type: 'Error', message: clip(s.split('\n    at ')[0]), frames: framesOfStack(s, root), text: clip(text) }
	}
	let frames
	if (Array.isArray(err.stacks) && err.stacks.length > 0) {
		frames = err.stacks.map((s) => frame(s.method, s.file, s.line, s.column, root))
	} else {
		frames = framesOfStack(err.stack || err.stackStr, root)
	}
	let message = err.message
	if (message === undefined && typeof err.stack === 'string') message = err.stack.split('\n    at ')[0]
	return {
		type: err.name || err.nameStr || 'Error',
		message: clip(plain(String(message ?? ''))),
		frames,
		diff: err.diff ? clip(err.diff) : undefined,
		text: text ? clip(text) : undefined,
	}
}

module.exports = { emitter, errorOf, framesOfStack, clip, plain, filePath }
