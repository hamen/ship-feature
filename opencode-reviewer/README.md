# opencode-reviewer: an optional reviewer for the glm seat

An opinionated reviewer setup for `ship-feature plan-review`'s `glm` seat on OpenCode v2. Nobody
gets it by default: the seat keeps its plain `plan` agent unless you opt in.

It has two parts:

- `agents/plan-reviewer.md`: a plan-review agent that checks every claim against the code, cites
  `file:line`, and drops findings it cannot back up. It may only read, grep, glob and list.
- `review-prompt-extra.md`: a required "Callers checked" step added to the prompt, so the reviewer
  looks for code the plan forgets.

## Use it

Add to `~/.config/ship-feature/config`, with the path to your ship-feature checkout:

```
GLM_REVIEW_CONFIG_DIR=/path/to/ship-feature/opencode-reviewer
GLM_REVIEW_AGENT=plan-reviewer
GLM_REVIEW_PROMPT_EXTRA=/path/to/ship-feature/opencode-reviewer/review-prompt-extra.md
```

To change it, copy the folder somewhere of your own and point the settings there. The seat copies
the folder fresh on each run, so a review never writes into it. With the folder set, the seat still
denies everything but read, grep and glob, unless the agent allows a tool by name. Edit, bash,
execute and the other write, shell and network tools stay denied either way (see the main README).

Tested on OpenCode 2.0.32: the agent's prompt is used, and it sees only read-only tools.

## Optional: codebase-memory

A code graph lets the reviewer find callers that grep misses. In our A/B runs, a reviewer with a
required graph step found a Blocker that later review rounds caught 2 times out of 3; the stock
seat found it 0 times out of 3. To add codebase-memory-mcp in your own copy of the folder:

1. Install it and index each repo you review (the reviewer cannot index).
2. Add an `opencode.json` to the folder:

   ```json
   {
     "mcp": {
       "servers": {
         "codebase-memory-mcp": {
           "type": "local",
           "command": ["/path/to/codebase-memory-mcp"],
           "codemode": false
         }
       }
     }
   }
   ```

   `codemode: false` puts its tools in the tool list instead of behind Code Mode, which the seat
   denies.
3. In the agent's frontmatter, allow its read tools by name. The seat denies every tool it is not
   told to allow, so an MCP tool missing from this list is not available:

   ```yaml
   permission:
     "*": deny
     read: allow
     grep: allow
     glob: allow
     list: allow
     codebase-memory-mcp_list_projects: allow
     codebase-memory-mcp_index_status: allow
     codebase-memory-mcp_search_graph: allow
     codebase-memory-mcp_trace_path: allow
     codebase-memory-mcp_get_code_snippet: allow
     codebase-memory-mcp_query_graph: allow
     codebase-memory-mcp_search_code: allow
     codebase-memory-mcp_get_architecture: allow
   ```

4. In the prompt extra, ask for the graph explicitly: a soft hint got zero calls in our tests. For
   example: "Call list_projects and use the project whose root_path is {repo}. For every symbol the
   plan changes, run search_graph and trace_path (inbound). Fall back to grep when it is not in the
   graph."

MCP tools only appear from the reviewer's second step, so do not make a graph call its first one.
