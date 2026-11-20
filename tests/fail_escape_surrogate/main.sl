// A UTF-16 surrogate half is not a character; JSON writes U+1F600 as
// \uD83D\uDE00, slang as \u{1F600}.
println("\uD83D\uDE00");
