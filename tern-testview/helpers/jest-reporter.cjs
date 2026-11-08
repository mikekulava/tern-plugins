// Test Explorer reporter for jest 26.5 and later: one JSON event per test case as it
// finishes (onTestCaseResult), then each file's full results with its console output.
'use strict'

const { emitter, errorOf, clip, plain } = require('./testview_js.cjs')

const emit = emitter()

const STATUS = { passed: 'passed', failed: 'failed', pending: 'skipped', skipped: 'skipped', todo: 'skipped', disabled: 'skipped' }

class TestviewReporter {
	constructor(globalConfig) {
		this.root = globalConfig?.rootDir || process.cwd()
	}

	onTestCaseResult(test, result) {
		this.result(test.path, result)
	}

	onTestResult(test, testResult) {
		const file = testResult.testFilePath || test.path
		if (testResult.testExecError) {
			const err = testResult.testExecError
			const e = errorOf(err, this.root, plain(testResult.failureMessage || ''))
			emit('file_error', { file, message: e.message, error: e })
		}
		for (const result of testResult.testResults ?? []) this.result(file, result)
		const logs = (testResult.console ?? []).map((entry) => `${entry.message}\n`).join('')
		if (logs) emit('output', { file, text: clip(logs) })
	}

	result(file, r) {
		const status = STATUS[r.status]
		if (!status) return
		const name = [...(r.ancestorTitles ?? []), r.title].join(' > ')
		let error
		if (status === 'failed') {
			const messages = r.failureMessages ?? []
			const text = plain(messages.join('\n\n'))
			// failureDetails cross the worker boundary without their stacks; the formatted
			// failure message still carries the stack lines.
			const first = plain(messages[0] ?? '')
			const detail = (r.failureDetails ?? []).find((d) => d && d.message) ?? {}
			error = errorOf(
				{
					name: detail.name ?? /^([A-Za-z]*Error)\b/.exec(first)?.[1] ?? 'Error',
					message: detail.message ?? first.split('\n    at ')[0],
					stack: detail.stack ?? first,
				},
				this.root,
				text,
			)
		}
		emit('result', {
			id: `${file}::${name}`,
			file,
			name,
			line: r.location?.line,
			status,
			duration: r.duration ?? undefined,
			error,
		})
	}

	onRunComplete() {
		emit('done', {})
	}

	getLastError() {
		return undefined
	}
}

module.exports = TestviewReporter
