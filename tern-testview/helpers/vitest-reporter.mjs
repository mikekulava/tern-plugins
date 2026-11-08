// Test Explorer reporter for vitest 2 and later: one JSON event per test as it finishes,
// file-level errors, then `done`. Vitest 3 added the test-case API (onTestCaseResult,
// onTestRunEnd) and vitest 4 removed the task API (onTaskUpdate, onFinished), so both are
// implemented; results are keyed by test id and a repeat is harmless.
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const { emitter, errorOf, clip, filePath } = require('./testview_js.cjs')

const emit = emitter()

function testId(file, fullName) {
	return `${file}::${fullName}`
}

const STATE_V2 = { pass: 'passed', fail: 'failed', skip: 'skipped', todo: 'skipped' }

export default class TestviewReporter {
	constructor() {
		this.root = process.cwd()
		this.logs = new Map() // task id -> output text
		this.emitted = new Set()
		this.finished = false
	}

	onInit(ctx) {
		this.ctx = ctx
		if (ctx?.config?.root) this.root = ctx.config.root
		// Test lines for the explorer; vitest 2 has no CLI flag for it, so set it before workers start.
		if (ctx?.config) ctx.config.includeTaskLocation = true
	}

	onUserConsoleLog(log) {
		const key = log.taskId ?? ''
		this.logs.set(key, (this.logs.get(key) ?? '') + (log.content ?? ''))
	}

	output(id) {
		const text = this.logs.get(id)
		return text ? clip(text) : undefined
	}

	// ---- vitest 3+: test cases and modules

	onTestCaseResult(testCase) {
		this.emitCase(testCase)
	}

	emitCase(testCase) {
		const result = testCase.result?.() ?? {}
		const state = result.state
		if (state !== 'passed' && state !== 'failed' && state !== 'skipped') return
		const file = filePath(testCase.module?.moduleId)
		const errors = result.errors ?? []
		this.result({
			id: testId(file, testCase.fullName),
			file,
			name: testCase.fullName,
			line: testCase.location?.line,
			status: state,
			duration: testCase.diagnostic?.()?.duration,
			error: errors.length ? errorOf(errors[0], this.root) : undefined,
			reason: state === 'skipped' ? result.note : undefined,
			output: this.output(testCase.id),
		})
	}

	onTestRunEnd(testModules) {
		if (this.finished) return
		for (const mod of testModules ?? []) {
			const file = filePath(mod.moduleId)
			for (const err of mod.errors?.() ?? []) this.fileError(file, err)
			for (const testCase of mod.children?.allTests?.() ?? []) this.emitCase(testCase)
		}
		this.done()
	}

	// ---- vitest 2-3: tasks

	onTaskUpdate(packs) {
		const idMap = this.ctx?.state?.idMap
		if (!idMap) return
		for (const [id] of packs ?? []) {
			const task = idMap.get(id)
			if (task?.type === 'test' && STATE_V2[task.result?.state]) this.emitTask(task)
		}
	}

	onFinished(files) {
		if (this.finished) return
		for (const file of files ?? []) {
			for (const err of file.result?.errors ?? []) this.fileError(filePath(file.filepath), err)
			this.walk(file)
		}
		this.done()
	}

	walk(task) {
		for (const child of task.tasks ?? []) {
			if (child.type === 'test') this.emitTask(child)
			else this.walk(child)
		}
	}

	emitTask(task) {
		const status = STATE_V2[task.result?.state] ?? (task.mode === 'skip' || task.mode === 'todo' ? 'skipped' : null)
		if (!status) return
		const names = []
		for (let t = task; t && !t.filepath; t = t.suite) names.unshift(t.name)
		const file = filePath(task.file?.filepath)
		const errors = task.result?.errors ?? []
		this.result({
			id: testId(file, names.join(' > ')),
			file,
			name: names.join(' > '),
			line: task.location?.line,
			status,
			duration: task.result?.duration,
			error: errors.length ? errorOf(errors[0], this.root) : undefined,
			output: this.output(task.id),
		})
	}

	// ---- shared

	result(fields) {
		// A result repeats across the old and new reporter hooks; send it again only when it
		// carries more, such as console output that arrived after the first one.
		const key = `${fields.id}\u0000${fields.status}\u0000${fields.output ? 1 : 0}`
		if (this.emitted.has(key)) return
		this.emitted.add(key)
		emit('result', fields)
	}

	fileError(file, err) {
		const e = errorOf(err, this.root)
		emit('file_error', { file, message: e.message, error: e })
	}

	done() {
		this.finished = true
		const stray = this.logs.get('')
		if (stray) emit('output', { text: clip(stray) })
		emit('done', {})
	}
}
