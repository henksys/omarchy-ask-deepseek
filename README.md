# Ask DeepSeek

Chat with DeepSeek from your Omarchy desktop. A summoned panel with a
scrollable conversation thread and a settings tab, keeping context from the
same config and history files as the terminal [ask single bash script](https://pages.github.com/).

## Install

```sh
omarchy plugin add https://github.com/henksys/omarchy-ask-deepseek.git --enable
```

## Usage

Press `SUPER + A` to open the panel (or summon it from any launcher):

```sh
omarchy-shell shell toggle io.github.henksys.ask
```

- Type a question and press Enter (or click Send).
- The conversation is shown as a thread: each question with its answer.
- Escape or the Close button closes the panel.
- **Clear** empties the conversation and deletes the history file.

### Settings tab

Opens from the panel header. You can change:

- **Role / system prompt**
- **Model** (deepseek-v4-flash or deepseek-v4-pro)
- **Thinking** mode and **Reasoning effort**
- **Temperature** and **Top P**
- **Output format** (text or json_object)
- **Save conversation history** (on/off)
- **Restore defaults** resets the config and clears history

Changes are saved to `~/.config/ask/config` and apply immediately.

## Configuration

Files shared with the terminal `ask` script:

| File | Purpose |
|------|---------|
| `~/.config/ask/config` | Settings (JSON, editable in the panel or by hand) |
| `~/.config/ask/key` | DeepSeek API key (optional, see below) |
| `~/.local/share/ask/history.jsonl` | Conversation history (JSONL, one message per line) |

The API key is read from the `DEEPSEEK_API_KEY` environment variable, falling
back to `~/.config/ask/key` when the variable is not set. The desktop shell is
started at login and does not see variables exported only in `~/.bashrc`, so
on a desktop install create the key file:

```sh
printf '%s\n' 'your-api-key' > ~/.config/ask/key
chmod 600 ~/.config/ask/key
```

The file should be readable only by your user (`chmod 600`).

## Remove

```sh
omarchy plugin remove io.github.henksys.ask
```

## Update

```sh
omarchy plugin update io.github.henksys.ask
```

## Requirements

- Omarchy (Hyprland + quickshell). Tested with Omarchy 4.0.1-1 and Quickshell version 0.3.1.
- curl (used for the DeepSeek API call)
- A DeepSeek API key in `DEEPSEEK_API_KEY`

## License

MIT
