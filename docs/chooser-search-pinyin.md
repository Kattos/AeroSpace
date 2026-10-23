# Chooser pinyin search

Chooser search also matches Chinese names by pinyin, in both full spelling and
initials. The matching code is
`Sources/AppBundle/ui/WorkspaceChooserSearch.swift`; it applies to the Option
chooser results and to persistent `aerospace workspace-chooser-search`, which
share this matcher. Nothing changes in the configuration format.

```
微信: wei, weixin, wx
企业微信: qiyeweixin, qywx
网易云音乐: wangyiyunyinle, wyyyl
```

Queries and labels are precomposed, folded for diacritics and character width,
lowercased, and split on whitespace and control characters, as before. The
pinyin aliases come from Foundation's system transliteration
(`applyingTransform(.toLatin)`), so the Chinese characters in a label are
transliterated to space-separated syllables and then exposed in two forms: the
syllables joined without spaces, and their first letters. A user typing `wei`
matches both `微信` and `企业微信`, because the query is compared against the
whole alias as an exact, prefix or ordered-subsequence match, just like a
literal label. Alias scoring is slightly worse than an equal literal score, so
`wx` prefers a workspace literally named `wx` over `微信`, and a Chinese or
English label typed exactly still ranks first. Ties keep the existing
deterministic workspace order.

Only Chinese characters are transliterated. Each CJK character becomes one
syllable, ASCII letters, digits and punctuation are dropped from the alias, and
labels without Chinese characters produce no aliases, so English fuzzy matching
keeps its previous behavior and cost. A mixed label such as `微信 dev 2024`
still matches `weixin` and `wx`, while `微信dev` typed literally keeps working
through the original label pass. Fullwidth Latin input and accented Latin
queries are folded before comparison.

Ranking keeps every literal label pass ahead of an equally good pinyin match:
literal exact, pinyin exact, literal prefix, pinyin prefix, then ordered
subsequences with fewer skipped characters. Pinyin matches one rank worse than a
literal match of the same quality are the reason `wx` prefers a workspace named
`wx` over `微信`, while typing `weixin` puts `微信` first even when another label
merely starts with those letters. Aliases are consulted only when the query
contains an ASCII letter, so a Chinese or symbol-only query does no
transliteration work. Labels without Chinese characters have no aliases, so
English results and ordering are unchanged.

## Limitations

This is system transliteration, not a dictionary: polyphonic characters use the
reading Foundation chooses, which may not be the reading you expect. Measured
here on macOS: `音乐` transliterates as `yīn lè`, so `网易云音乐` becomes
`wangyiyunyinle` with initials `wyyyl`; `长` alone is `zhǎng`, `厦门` is
`shà mén`, and `重庆` is `chóng qìng`. Alias initials therefore follow the same
syllables, and multi-character context does not fix every polyphone.
Rare or non-BMP ideographs may transliterate as an unexpected syllable or not at
all. No alternate pronunciations, dialect readings, or per-character overrides
are generated, and no pinyin dictionary or external package is used.

Aliases are derived once per label per search call, locally in the matcher.
There is no persistent cache. Alias derivation runs only when the query contains
an ASCII letter and the label contains at least one ideographic character, so
ordinary English typing pays no transliteration cost.

## Scope

Pinyin applies to search only. `[workspace-chooser-colors]` substring rules and
`[auto-place]` keys keep their literal, case-insensitive semantics; pinyin
spellings do not color entries or place applications. Search results keep their
existing scoring for non-CJK input, and an empty query still returns the
ordinary workspace list with the existing empty-workspace filter.

The matcher has no build artifact of its own. It was checked with standalone
Swift assertions outside the repository against the real Foundation framework.
The combined Release build and runtime typing verification are separate steps.
