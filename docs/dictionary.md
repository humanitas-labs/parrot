# Dictionary

Last updated: `2026.10.01`

> Your names and technical terms, so Parrot spells them the way you do. One plain-text file, edited by hand or with Fix Word…, applied on the next dictation.

The file is `~/.config/parrot/dictionary` (or `$XDG_CONFIG_HOME/parrot/dictionary`), with no extension. **Open Dictionary File** in Settings opens it in your default text editor. The first run creates a small starter file. A filled-in one looks like this:

```
# Words Parrot should spell your way. Replaces lists what it writes instead.
# Separate the columns with two spaces or a tab.

Word          Replaces
Vercel        Versailles, Vercell, ver cell
Omnigraph     omni graph, omnigraf
WhisperKit    whisper kit
Parakeet
```

Each line is one word, spelled the way you want it, and optionally what the model writes instead of it. Separate the two columns with a tab or two or more spaces; the columns don't need to line up. A single space belongs to the word, so `Claude Code` is one entry. Replaces is a comma-separated list and may be left out, as for `Parakeet`. Blank lines, lines starting with `#`, and the `Word  Replaces` header are ignored.

Every word is a canonical spelling: written in any casing, it is rewritten to yours, so `whisperkit` becomes `WhisperKit`. Each item in its Replaces list is rewritten to the word. Use Replaces for words the model splits or mishears.

The rewrite runs on every transcript. It matches whole words only (`api` never changes `rapid`), ignores case, and works in any script. When two entries match at the same place, the longer one wins. Each word is rewritten at most once, so one entry's output never feeds another, and the word is inserted exactly as written. An item in a Replaces list takes precedence over the same text as a word of its own. However many entries you add, they cost nothing noticeable, because they rewrite the finished text and never reach the model.

## Fix Word…

To add a word without opening the file, select what Parrot wrote in any app, then choose **Fix Word…** in the Parrot menu, or **Services → Fix Word in Parrot** in that app's menu. Type the spelling you want and click **Add**.

- **Replace “…” in every dictation** adds what Parrot wrote to the word's Replaces list. It starts off when what Parrot wrote is an everyday word, because the row would change that word in every dictation. The panel warns when a row would change ordinary text.
- Without Replace, the row only keeps the word's spelling.
- A new word goes under `# Added by Parrot` at the end of the file. A word that is already there keeps its line, and Parrot adds the item to it. Every other line stays byte for byte as it was, comments included.
- **Undo Fix Word** in the Parrot menu takes back the last fix: the whole row when Fix Word added it, else only the item.

To give Fix Word a shortcut, open **System Settings → Keyboard → Keyboard Shortcuts → Services** and find **Fix Word in Parrot** under Text.

Parrot reads the selection only when you choose Fix Word, never in a password field, and only up to four words.

## Example sentences

An example sentence is what Whisper reads as the speech just before yours, which biases it toward your spellings. It lives in `~/.config/parrot/settings.json` under `dictionary.examples`, one sentence per language, keyed by language code (`en`, `pt-BR`):

```json
{
  "dictionary": {
    "examples": {
      "en": "I pushed the WhisperKit fix and checked the Vercel dashboard before the review."
    }
  }
}
```

Write it the way you dictate: "I need to review the pull requests before the merge" works; "I am a developer who uses technical terms" does not, and neither does a bare list of words. One sentence is enough: Whisper reads it before every dictation, so it adds time on `whisper-base.en`: about 35–40 ms for a 9-word sentence and 85–100 ms for a 19-word one. Parrot only uses the sentence for the language being spoken, because a sentence in the wrong language pulls the model into that language. The English-only models (the default `whisper-base.en` and `whisper-small.en`) use the English sentence. A multilingual model uses the sentence for the Language chosen in Settings, or in Automatic, the sentence for the language it detects in each dictation.

## Edits and mistakes

Edits apply on the next dictation, with no restart. If the file has a mistake, Parrot keeps using the last version that loaded and logs the line number to `~/Library/Logs/parrot/`, without quoting the line. The usual mistake is a single space between the word and its Replaces list, as in `Vercel Versailles, Vercell`: a comma in the word column means the separator is missing, so Parrot refuses the file rather than guess where the word ends.

The file can live in a dotfiles repository: `~/.config/parrot`, or `dictionary` itself, may be a symlink, as long as the file it points to is yours.

## From dictionary.json

Earlier versions kept the dictionary in `dictionary.json`. On the first launch after the update, if `dictionary` does not exist and `dictionary.json` does, Parrot converts it once: each term and each replacement target becomes a row with its replacements, the example sentences move into `settings.json` under `dictionary.examples` (unless it already has some), and `dictionary.json` is renamed to `dictionary.json.bak`. If `dictionary.json` was a symlink into a dotfiles repository, the new file is written in `~/.config/parrot` and the link itself is renamed; the file in the repository is left untouched, so move `dictionary` there and link it back if you want it tracked. If `dictionary.json` has a mistake, it is left as it was, the problem is logged, and the conversion runs again on the next launch.
