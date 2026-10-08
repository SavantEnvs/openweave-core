// Build-time LeakSanitizer switch (fleet policy): leaks are not the bug class fuzzed here.
// ASan's memory-error checks and UBSan stay on and halting. Linked into every fuzz and
// -standalone binary by mayhem/build.sh.
extern "C" int __lsan_is_turned_off() { return 1; }
