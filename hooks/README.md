# Hooks

Python files that Aviary calls at points in the agent loop. Drop one in this directory and it
is loaded on the next in-house run.

A hook file defines `on_<event>(payload)` functions. There is nothing to register and nothing
to import — the file is the interface. Return a dict to change what happens; return `None` to
observe and let it proceed.

Hooks run in their own interpreter, separate from every agent session, so a hook cannot read a
session's variables and a broken hook cannot corrupt one. **A hook that raises is reported and
ignored:** one bad extension must never take the run with it.

## Events

### `on_before_tool(payload) -> dict | None`

Called before a tool call runs. `payload` has `name`, `code` and `session`.

```python
def on_before_tool(payload):
    code = payload["code"]
    if "rm -rf" in code:
        return {"block": True, "reason": "Refusing a recursive delete. Move it to /tmp instead."}
    return None
```

Return `{"block": True, "reason": …}` to refuse — the reason goes to the model as the tool
result, so write it as an instruction rather than a complaint. Return `{"code": …}` to rewrite
the call; the rewrite is noted in the transcript, because a silently altered call would make the
record lie about what ran.

Because `python` is the only built-in tool, this one event is a complete permission system.

## Chaining

Every hook that defines an event is called, in load order, and each sees the decisions of the
ones before it — so a chain refines rather than fights. The last write wins.
