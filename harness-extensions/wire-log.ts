/**
 * Records every provider request payload to a JSONL file, so Aviary can show exactly
 * what was sent to the model.
 *
 * This exists because a session transcript cannot answer "what were those 17,000 input
 * tokens?". The transcript holds messages; the system prompt, the discovered AGENTS.md
 * files, the skill descriptions and the tool schemas are assembled at request time and
 * never persisted anywhere. The harness's `before_provider_request` hook fires after the
 * provider-specific payload is built and immediately before it is sent — the docs describe
 * it as being for exactly this, "debugging provider serialization" — so the payload is
 * available; nothing was storing it.
 *
 * Deliberately an extension rather than a change to the forked harness. The hook is a
 * public contract, so this needs no divergence, and it stays opt-in per run: recording
 * payloads means writing your full system prompt and conversation to a file, which should
 * never be something that happens without asking.
 *
 * Aviary loads it with `-e <this file>` and sets AVIARY_WIRE_LOG_PATH. Run it by hand the
 * same way:
 *
 *   AVIARY_WIRE_LOG_PATH=/tmp/wire.jsonl prime-agent -e harness-extensions/wire-log.ts
 *
 * The payload is passed through unchanged — the hook can rewrite requests, and this one
 * never does.
 */

// Typed loosely on purpose: the file is loaded from an arbitrary path by `-e`, where
// `@earendil-works/pi-coding-agent` may not resolve. A type-only import would be erased,
// but not resolving at all is one less thing to go wrong.
type Json = unknown;

interface WireLogRecord {
	v: 1;
	seq: number;
	at: string;
	kind: "request" | "response";
	/** The exact object handed to the provider, post-serialization-shaping. */
	payload?: Json;
	status?: number;
	headers?: Record<string, string>;
}

export default function (pi: {
	on: (event: string, handler: (event: Record<string, Json>, ctx: unknown) => unknown) => void;
}) {
	const path = process.env.AVIARY_WIRE_LOG_PATH;
	if (!path) {
		// No destination means the feature is off. Say nothing: a warning on every launch
		// would be noise for the overwhelmingly common case.
		return;
	}

	let seq = 0;
	let broken = false;

	const append = (record: WireLogRecord): void => {
		if (broken) return;
		try {
			// Lazy require so a run with the feature off never touches node:fs.
			const fs = require("node:fs") as typeof import("node:fs");
			const dir = path.slice(0, Math.max(0, path.lastIndexOf("/")));
			if (dir) fs.mkdirSync(dir, { recursive: true });
			fs.appendFileSync(path, `${JSON.stringify(record)}\n`, "utf-8");
		} catch {
			// One failure is enough to stop trying. Diagnostics must never take down a run,
			// and a full disk should not produce one error per model call.
			broken = true;
		}
	};

	pi.on("before_provider_request", (event) => {
		append({
			v: 1,
			seq: seq++,
			at: new Date().toISOString(),
			kind: "request",
			payload: event.payload,
		});
		// Returning undefined leaves the payload untouched.
		return undefined;
	});

	pi.on("after_provider_response", (event) => {
		append({
			v: 1,
			seq: seq++,
			at: new Date().toISOString(),
			kind: "response",
			status: typeof event.status === "number" ? event.status : undefined,
			headers: (event.headers as Record<string, string>) ?? undefined,
		});
		return undefined;
	});
}
