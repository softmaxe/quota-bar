# QuotaBar demo film

This directory will contain the hand-drawn English and Chinese README films specified in
[issue #76](https://github.com/softmaxe/quota-bar/issues/76).

The film follows the Menu bar robot through five Beats: quota runs out, one glance,
running low and reset, every dollar, and report and outro. Captions carry the story
without narration. The app interface stays in English in both films.

## Implementation

The Remotion and TypeScript picture and the uv-managed Python audio package share
an exported timeline. The renderer produces two 75-second MP4s and PNG review frames.
Music and sound effects are synthesized in code.

- #77 establishes the build and test pipeline.
- #78 and #79 add the character and interface kit after #77.
- #80 through #84 implement the five Beats after #78 and #79.
- #85 adds the score after #77.
- #86 replaces the old demo and finishes the documentation after the Beats and score.

The Swift app and its CI remain outside this implementation.
