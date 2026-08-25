// the library name flows into a shell command line in main.c; only a
// conservative charset is allowed to close off command injection
link "foo; touch /tmp/pwned_marker";
