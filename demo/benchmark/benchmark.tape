# VHS Tape — zq vs jq benchmark comparison
# Install VHS: https://github.com/charmbracelet/vhs
# Prerequisites: jq, zq (in PATH), hyperfine, awk
# Record: vhs demo/benchmark.tape

Output demo/benchmark.gif

Set Shell "bash"
Set FontSize 18
Set Width 1000
Set Height 550
Set Theme "Dracula"
Set TypingSpeed 30ms
Set Padding 20

# Setup: clean prompt, PATH, generate data (hidden from recording)
Hide
Type `export PS1="$ " PATH="/home/hybridz/Projects/zq/zig-out/bin:$PATH" && awk 'BEGIN{for(i=1;i<=1000000;i++) printf "{\"id\":%d,\"name\":\"user_%d\",\"active\":true}\n",i,i}' > /tmp/bench.jsonl && clear`
Enter
Sleep 3s
Show

# --- Act 1: Feel the difference ---
Type "# 1M records  |  45 MB  |  .id extraction"
Enter
Sleep 500ms

Type "time jq '.id' /tmp/bench.jsonl > /dev/null"
Enter
# jq takes ~1.7s
Sleep 3s

Type "time zq '.id' /tmp/bench.jsonl > /dev/null"
Enter
# zq takes ~0.09s — instant
Sleep 1.5s

# --- Act 2: Prove it ---
Enter
Type "hyperfine --warmup 1 --runs 2 'jq .id /tmp/bench.jsonl' 'zq .id /tmp/bench.jsonl'"
Enter
# warmup + 2 runs each + summary — ~8s total
Sleep 12s

Sleep 3s
