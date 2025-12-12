# Manifest Reference (llm-cost.toml)

The `llm-cost.toml` file is the central configuration for `llm-cost`. It defines budget limits, policy constraints (allowed models), and manages prompt governance.

## Format
`llm-cost` uses a **minimalist TOML v1.0 subset parser**.
- Supports `[sections]`.
- Supports `[[array_of_tables]]`.
- Supports key-value pairs (`key = "value"` or `key = 123`).
- Supports string arrays (`["a", "b"]`).
- Supports inline tables (`{ k = "v" }`).
- Comments start with `#`.

## Schema

### 1. `[budget]` (Optional)
Defines cost limits for the `check` command.

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `max_cost_usd` | Float | `null` | Maximum allowed estimated cost for a run. Exceeding this triggers exit code 2. |
| `warn_threshold` | Float | `0.8` | (Reserved for future usage) Threshold to trigger warnings. |

```toml
[budget]
max_cost_usd = 10.00
```

---

### 2. `[policy]` (Optional)
Defines governance rules.

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `allowed_models` | Array<String> | `null` (All) | List of permitted model IDs. Usage of other models triggers exit code 3. |

```toml
[policy]
allowed_models = ["gpt-4o", "gpt-4o-mini"]
```

---

### 3. `[defaults]` (New in v0.10)
Sets default values for commands like `check` and `estimate` when no model is specified.

| Key | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `model` | String | `null` | Default model to use for files without explicit override. |

```toml
[defaults]
model = "gpt-4o-mini"
```

---

### 4. `[[prompts]]` (New in v0.10)
Defines the list of managed prompts. This is used by `check` (in Manifest Mode) and `estimate` to determine stable `prompt_id`s.

| Key | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `path` | String | **Yes** | Path to the prompt file (relative to manifest). |
| `prompt_id` | String | No | Stable identifier for the prompt (e.g., `login-v1`). **Recommended** for stable prompt tracking and required for FOCUS compliance, but optional otherwise. If omitted, a warning will be issued. |
| `model` | String | No | Specific model to use for this prompt (overrides global defaults). |
| `tags` | Inline Table | No | Metadata tags (e.g., `{ team = "auth" }`). |

```toml
[[prompts]]
path = "prompts/login.txt"
prompt_id = "login-prompt-v1"
model = "gpt-4o"
tags = { team = "auth", criticality = "high" }

[[prompts]]
path = "prompts/search.txt"
prompt_id = "search-prompt"
# Inherits default model
```

## Example Configuration

```toml
# llm-cost.toml
[defaults]
model = "gpt-4o-mini"

[budget]
max_cost_usd = 50.00

[policy]
allowed_models = ["gpt-4o", "gpt-4o-mini"]

[[prompts]]
path = "prompts/onboarding.md"
prompt_id = "onboarding-v2"
tags = { owner = "growth" }

[[prompts]]
path = "prompts/data_analysis.txt"
prompt_id = "analysis-main"
model = "gpt-4o"
```
