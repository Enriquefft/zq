# VHS Tape — zq vs jq short clip for X/Twitter
# Optimized for impact: ~15 seconds, punchy, visual
# Install VHS: https://github.com/charmbracelet/vhs
# Record: vhs demo/x-post/x-post.tape

Output demo/x-post/x-post.gif

Set Shell "bash"
Set FontSize 22
Set Width 800
Set Height 400
Set Theme "Dracula"
Set TypingSpeed 20ms
Set Padding 20

# Setup: generate 6M records (~270 MB), clean prompt (hidden)
Hide
Type `export PS1="$ " PATH="/home/hybridz/Projects/zq/zig-out/bin:$PATH" && awk 'BEGIN{for(i=1;i<=6000000;i++) printf "{\"id\":%d,\"name\":\"user_%d\",\"active\":true}\n",i,i}' > /tmp/bench.jsonl && clear`
Enter
Sleep 15s
Show

# Title
Type "# 6M JSON records — .id extraction"
Enter
Sleep 800ms

# jq — the slow one (~10s)
Type "time jq '.id' /tmp/bench.jsonl > /dev/null"
Enter
Sleep 12s

# zq — the punchline (~0.3s)
Type "time zq '.id' /tmp/bench.jsonl > /dev/null"
Enter
Sleep 2s

# Let it sink in
Sleep 2s
