Output assets/demo.gif
Set Shell "bash"
Set FontFamily "Maple Mono Medium"
Set FontSize 14
Set LetterSpacing 0
Set LineHeight 1.1
Set Width 860
Set Height 560
Set Padding 12
Set Theme "Monokai Pro (Filter Ristretto)"
Set TypingSpeed 25ms

Type "curl -s localhost:8080/mlb | head -30"
Enter
Sleep 2500ms
Type "sprts-tui mlb --plain --host http://localhost:8080 | head -12"
Enter
Sleep 2000ms
Type "sprts-tui mlb --host http://localhost:8080"
Enter
Sleep 2500ms
Type "j"
Sleep 500ms
Type "k"
Sleep 500ms
Type "j"
Sleep 500ms
Enter
Sleep 2500ms
Type "b"
Sleep 700ms
Type "q"
Sleep 600ms
Type "# live board as SSE (data: prefix stripped for display)"
Enter
Sleep 400ms
Type "timeout 5 curl -sN 'localhost:8080/mlb?stream=sse' | sed 's/^data: //; /^data:$/d'"
Enter
Sleep 5600ms
Type "# Phillies live right now: stream their game"
Enter
Sleep 400ms
Type "timeout 4 curl -sN 'localhost:8080/mlb/401816884?stream=sse'"
Enter
Sleep 4600ms
