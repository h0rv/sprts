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

Type "curl -s localhost:8080/mlb | head -20"
Enter
Sleep 2500ms
Type "sprts-tui mlb --plain --host http://localhost:8080 | head -12"
Enter
Sleep 2500ms
Type "sprts-tui mlb --host http://localhost:8080"
Enter
Sleep 5000ms
Type "q"
Sleep 700ms
Type "# tour stream, no browser needed"
Enter
Type "timeout 5 curl -sN 'localhost:8080/mlb?stream=sse'"
Enter
Sleep 6500ms
