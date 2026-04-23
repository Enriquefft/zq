//! zq-regex-shim — static C ABI over regex-automata.
//!
//! Phase B: full surface — compile/free, clone/clone_free, is_match on clone,
//! find, find_captures, iter_next, captures metadata (count, name lookup,
//! index lookup), last_error. Every FFI entry wraps its body in
//! `std::panic::catch_unwind`. On caught panic:
//!   - pointer-returning functions return NULL
//!   - int-returning functions return -1
//!   - last error message is captured in thread-local storage
//!
//! Thread model:
//!   - `ZqRegex` wraps `regex_automata::meta::Regex`. Sync, shared across
//!     workers.
//!   - `ZqRegexClone` owns a per-worker `Cache`, plus an `Arc`-cheap clone of
//!     the compiled `Regex`. All hot-path searches go through
//!     `search_slots_with` / `search_half_with` to bypass the internal
//!     `Pool<Cache>` entirely — this is BurntSushi's documented escape hatch
//!     for multi-threaded short-haystack workloads (rust-lang/regex#960).
//!
//! Slot sentinel: unmatched optional groups leave `start == usize::MAX` in
//! the caller's `ZqMatchSlot` array.

#![deny(unsafe_op_in_unsafe_fn)]

use std::cell::RefCell;
use std::ffi::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;

use regex_automata::meta::{Cache, Regex as MetaRegex};
use regex_automata::util::primitives::NonMaxUsize;
use regex_automata::{Input, PatternID};
use regex_syntax::hir::literal::Extractor;
use regex_syntax::parse as parse_hir;

/// Opaque compiled-pattern handle. Struct layout is hidden; callers only ever
/// see `*mut ZqRegex` / `*const ZqRegex` and must not dereference it.
pub struct ZqRegex {
    inner: MetaRegex,
    /// Cached literal extraction for the Sparser prefilter. Computed once at
    /// compile time so `zq_regex_required_literals` is a cheap pointer hand-out.
    /// `None` means the pattern has no extractable literals (infinite / empty
    /// set from `regex_syntax::hir::literal::Extractor`) — prefilter must be
    /// disabled for this regex.
    literals: Option<ZqLiterals>,
}

/// Prefilter literal set for Sparser-style raw-byte prescreening.
///
/// `is_exhaustive == true` — every literal in `items` is required (AND). Used
/// for single-literal patterns where the regex cannot match without those bytes
/// appearing verbatim. Example: `"hello"` → `{items=["hello"], exhaustive=true}`.
///
/// `is_exhaustive == false` — any one of `items` appearing is necessary (OR).
/// Used for alternations: `"foo|bar"` → `{items=["foo","bar"], exhaustive=false}`.
///
/// We filter out literals shorter than 2 bytes (SIMD scan overhead beats
/// selectivity gain for single-byte literals on typical JSONL payloads), and
/// dedupe — a deduped set is cheaper to scan and never changes correctness.
pub struct ZqLiterals {
    items: Vec<Vec<u8>>,
    is_exhaustive: bool,
}

/// Minimum useful literal length. Patterns whose literal extraction reduces to
/// single bytes are better served by letting the full regex engine run: the
/// per-byte SIMD memchr cost vs. selectivity tradeoff goes negative.
const MIN_LITERAL_LEN: usize = 2;

/// Extract prefilter literals from a regex pattern string. Returns `None` if
/// the Extractor yields an infinite / empty sequence, or if every extracted
/// literal is shorter than `MIN_LITERAL_LEN`.
///
/// Semantics mapping (prefix-extraction mode, which is the Extractor default):
///
/// - A Seq is a PREFIX COVER: every match of the regex must START with at
///   least one of the literals in the Seq (regex-syntax documents this as
///   the prefix contract).
/// - Therefore a Seq with N literals always has OR-semantics from the
///   prefilter's point of view: it suffices for ONE literal to appear.
/// - The exception is N == 1: a single prefix literal must appear on every
///   match, so it's simultaneously "any one required" and "that one
///   required" — we label this AND for efficiency (scanning is the same,
///   but keeping the label lets us reason about multi-group AND composition
///   below).
///
/// `Seq::is_exact()` has a subtly different meaning (every extracted literal
/// reaches the match state, i.e., represents a full accepting path). It is
/// NOT a reliable proxy for AND-vs-OR prefilter semantics. Use count instead.
fn extract_literals_from_pattern(pattern: &str) -> Option<ZqLiterals> {
    let hir = parse_hir(pattern).ok()?;
    let seq = Extractor::new().extract(&hir);
    // `literals()` returns None when the sequence is infinite — unbounded
    // patterns like `.+` or `\d+` cannot be prefiltered; fall through.
    let lits = seq.literals()?;
    if lits.is_empty() {
        return None;
    }

    // Dedup while preserving order. The Extractor can produce duplicate
    // literals from overlapping extraction paths (suffix/prefix union).
    let mut seen: std::collections::HashSet<Vec<u8>> = std::collections::HashSet::new();
    let mut items: Vec<Vec<u8>> = Vec::with_capacity(lits.len());
    for lit in lits.iter() {
        let bytes = lit.as_bytes();
        if bytes.len() < MIN_LITERAL_LEN {
            continue;
        }
        if seen.insert(bytes.to_vec()) {
            items.push(bytes.to_vec());
        }
    }
    if items.is_empty() {
        return None;
    }
    // A single prefix literal must appear (AND). Multiple prefix literals
    // form an OR-cover — any one appearing is sufficient.
    let is_exhaustive = items.len() == 1;
    Some(ZqLiterals { items, is_exhaustive })
}

/// Opaque per-worker clone. Holds a cheap clone of the meta::Regex (shares
/// the compiled DFA via internal `Arc`s) plus a fresh `Cache` — searches via
/// this clone never hit the shared pool.
pub struct ZqRegexClone {
    inner: MetaRegex,
    cache: Cache,
}

/// Layout-stable match slot handed across the FFI boundary. Mirrors the Zig
/// side's `MatchSlot` extern struct. `start == usize::MAX` encodes "this
/// optional group did not participate in the match".
#[repr(C)]
#[derive(Clone, Copy)]
pub struct ZqMatchSlot {
    pub start: usize,
    pub end: usize,
}

const SLOT_UNMATCHED: usize = usize::MAX;

thread_local! {
    static LAST_ERROR: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn set_last_error(msg: impl Into<String>) {
    LAST_ERROR.with(|cell| *cell.borrow_mut() = Some(msg.into()));
}

fn clear_last_error() {
    LAST_ERROR.with(|cell| *cell.borrow_mut() = None);
}

/// Run `body` inside `catch_unwind`. On panic, record a generic error string
/// and return `on_panic`. This keeps the zq process alive when Rust panics.
///
/// Invariant: if `body` panics after mutating `ZqRegexClone::cache`, the cache
/// may be in an inconsistent state. regex-automata's searcher is specified not
/// to leave the cache corrupt on panic, but callers that observe a panicked
/// return code (`-1`/`NULL`) MUST treat the originating clone as poisoned and
/// drop it instead of reusing it. The Zig side enforces this at the
/// `Error.RegexInternalError` boundary.
fn guarded<T, F>(on_panic: T, body: F) -> T
where
    F: FnOnce() -> T,
{
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(payload) => {
            let msg = if let Some(s) = payload.downcast_ref::<&'static str>() {
                (*s).to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "zq-regex-shim: panic with non-string payload".to_string()
            };
            set_last_error(format!("panic: {msg}"));
            on_panic
        }
    }
}

// ─── compile / free ───────────────────────────────────────────────────────────

/// Compile a UTF-8 regex pattern. Pointer is valid until `zq_regex_free`.
///
/// Returns NULL on compile error or panic. Retrieve the error message via
/// `zq_regex_last_error`.
///
/// # Safety
/// `pat` must point to `pat_len` valid bytes. `pat_len == 0` is allowed.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_compile(pat: *const u8, pat_len: usize) -> *mut ZqRegex {
    guarded(ptr::null_mut::<ZqRegex>(), || {
        if pat.is_null() && pat_len != 0 {
            set_last_error("zq_regex_compile: NULL pattern with non-zero length");
            return ptr::null_mut();
        }

        // SAFETY: caller contract asserts pat..pat+pat_len is valid.
        let bytes = if pat_len == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(pat, pat_len) }
        };

        let pattern = match std::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(e) => {
                set_last_error(format!("pattern is not valid UTF-8: {e}"));
                return ptr::null_mut();
            }
        };

        match MetaRegex::new(pattern) {
            Ok(inner) => {
                clear_last_error();
                // Literal extraction is best-effort: a failure here (None)
                // simply disables prefilter for this regex; compilation still
                // succeeds. We reparse to HIR because regex_automata's meta
                // engine does not expose the HIR publicly.
                let literals = extract_literals_from_pattern(pattern);
                Box::into_raw(Box::new(ZqRegex { inner, literals }))
            }
            Err(e) => {
                set_last_error(format!("{e}"));
                ptr::null_mut()
            }
        }
    })
}

/// Free a regex previously returned by `zq_regex_compile`.
///
/// # Safety
/// `handle` must be either NULL or a pointer returned by `zq_regex_compile`
/// that has not yet been freed. Calling this with any other value is UB.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_free(handle: *mut ZqRegex) {
    guarded((), || {
        if handle.is_null() {
            return;
        }
        // SAFETY: guarded by caller contract above.
        drop(unsafe { Box::from_raw(handle) });
    });
}

// ─── metadata ─────────────────────────────────────────────────────────────────

/// Return the number of capturing groups for the compiled pattern, **including
/// the implicit group 0** (the full match). Therefore group indices in range
/// `0..capture_count` are valid for `zq_regex_group_name` and for slot pairs in
/// the find/iter APIs.
///
/// Returns 0 on NULL handle or panic.
///
/// # Safety
/// `handle` must be a live pointer from `zq_regex_compile`.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_capture_count(handle: *const ZqRegex) -> usize {
    guarded(0usize, || {
        if handle.is_null() {
            set_last_error("zq_regex_capture_count: NULL regex handle");
            return 0;
        }
        // SAFETY: caller contract.
        let regex = unsafe { &*handle };
        regex.inner.captures_len()
    })
}

/// Look up the name of capture group `idx`. Returns:
///   -  1 with `*out_name`/`*out_len` populated if the group is named
///   -  0 with `*out_len == 0` if the group exists but is unnamed
///   - -1 on OOB `idx`, NULL handle, or panic
///
/// The name bytes are valid for the lifetime of `handle` (interned inside the
/// compiled regex — never freed independently, never mutated).
///
/// # Safety
/// `handle` must be live. `out_name` and `out_len` must be non-null and
/// writable (writes are unconditional on success, skipped otherwise).
#[no_mangle]
pub unsafe extern "C" fn zq_regex_group_name(
    handle: *const ZqRegex,
    idx: usize,
    out_name: *mut *const u8,
    out_len: *mut usize,
) -> i32 {
    guarded(-1i32, || {
        if handle.is_null() || out_name.is_null() || out_len.is_null() {
            set_last_error("zq_regex_group_name: NULL argument");
            return -1;
        }
        // SAFETY: caller contract.
        let regex = unsafe { &*handle };
        let info = regex.inner.group_info();
        if idx >= regex.inner.captures_len() {
            set_last_error("zq_regex_group_name: group index out of bounds");
            return -1;
        }
        match info.to_name(PatternID::ZERO, idx) {
            Some(name) => {
                let bytes = name.as_bytes();
                // SAFETY: out pointers non-null (checked above).
                unsafe {
                    *out_name = bytes.as_ptr();
                    *out_len = bytes.len();
                }
                1
            }
            None => {
                // SAFETY: out pointers non-null (checked above).
                unsafe {
                    *out_name = ptr::null();
                    *out_len = 0;
                }
                0
            }
        }
    })
}

/// Look up the group index for a named capture. Returns the index on hit, -1
/// on miss or error. Name is interpreted as UTF-8; invalid UTF-8 → -1.
///
/// # Safety
/// `handle` must be live. `name` must point to `name_len` readable bytes (or
/// `name_len == 0` and `name` may be NULL).
#[no_mangle]
pub unsafe extern "C" fn zq_regex_group_index_by_name(
    handle: *const ZqRegex,
    name: *const u8,
    name_len: usize,
) -> isize {
    guarded(-1isize, || {
        if handle.is_null() {
            set_last_error("zq_regex_group_index_by_name: NULL regex handle");
            return -1;
        }
        if name.is_null() && name_len != 0 {
            set_last_error("zq_regex_group_index_by_name: NULL name with non-zero length");
            return -1;
        }
        // SAFETY: caller contract.
        let regex = unsafe { &*handle };
        let bytes = if name_len == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(name, name_len) }
        };
        let name_str = match std::str::from_utf8(bytes) {
            Ok(s) => s,
            Err(_) => {
                set_last_error("zq_regex_group_index_by_name: name is not valid UTF-8");
                return -1;
            }
        };
        match regex.inner.group_info().to_index(PatternID::ZERO, name_str) {
            Some(idx) => idx as isize,
            None => -1,
        }
    })
}

// ─── clone / clone_free ───────────────────────────────────────────────────────

/// Per-worker clone. Shares the compiled strategy via internal `Arc`, but
/// allocates a fresh `Cache`. Subsequent searches through the returned clone
/// bypass the shared `Pool<Cache>` entirely — eliminating contention on short
/// haystacks from multiple worker threads.
///
/// Returns NULL on NULL input, allocator failure, or panic.
///
/// # Safety
/// `handle` must be a live pointer from `zq_regex_compile`.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_clone(handle: *const ZqRegex) -> *mut ZqRegexClone {
    guarded(ptr::null_mut::<ZqRegexClone>(), || {
        if handle.is_null() {
            set_last_error("zq_regex_clone: NULL regex handle");
            return ptr::null_mut();
        }
        // SAFETY: caller contract.
        let regex = unsafe { &*handle };
        // meta::Regex::clone bumps an Arc for the strategy and creates a new
        // Pool. We never use the clone's Pool — we call the `_with` methods
        // with our own Cache instead.
        let inner = regex.inner.clone();
        let cache = inner.create_cache();
        clear_last_error();
        Box::into_raw(Box::new(ZqRegexClone { inner, cache }))
    })
}

/// Free a clone previously returned by `zq_regex_clone`.
///
/// # Safety
/// `clone` must be either NULL or a pointer returned by `zq_regex_clone` that
/// has not yet been freed. Calling this with any other value is UB.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_clone_free(clone: *mut ZqRegexClone) {
    guarded((), || {
        if clone.is_null() {
            return;
        }
        // SAFETY: guarded by caller contract above.
        drop(unsafe { Box::from_raw(clone) });
    });
}

// ─── search primitives ────────────────────────────────────────────────────────

/// Shared NULL-check + slice-reconstruction helper for clone-based searches.
/// Returns the haystack slice or a sentinel that the caller turns into -1.
fn resolve_clone_and_hay<'a>(
    clone: *mut ZqRegexClone,
    hay: *const u8,
    hay_len: usize,
    fn_name: &'static str,
) -> Option<(&'a mut ZqRegexClone, &'a [u8])> {
    if clone.is_null() {
        set_last_error(format!("{fn_name}: NULL clone handle"));
        return None;
    }
    if hay.is_null() && hay_len != 0 {
        set_last_error(format!("{fn_name}: NULL haystack with non-zero length"));
        return None;
    }
    // SAFETY: caller contract; we have exclusive access to the clone for the
    // duration of the FFI call (caller promises no other thread touches it).
    let c = unsafe { &mut *clone };
    let haystack: &[u8] = if hay_len == 0 {
        &[]
    } else {
        // SAFETY: caller contract.
        unsafe { slice::from_raw_parts(hay, hay_len) }
    };
    Some((c, haystack))
}

/// Test whether the pattern matches anywhere in `hay`. Goes through the
/// per-worker cache (no pool contention).
///
/// Returns 1 on match, 0 on no match, -1 on internal error or panic.
///
/// # Safety
/// `clone` must be a live pointer from `zq_regex_clone`. `hay` must point to
/// `hay_len` valid bytes.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_is_match_clone(
    clone: *mut ZqRegexClone,
    hay: *const u8,
    hay_len: usize,
) -> i32 {
    guarded(-1i32, || {
        let (c, haystack) = match resolve_clone_and_hay(clone, hay, hay_len, "zq_regex_is_match_clone") {
            Some(t) => t,
            None => return -1,
        };
        // `search_half_with` + earliest is the cache-aware is_match.
        let input = Input::new(haystack).earliest(true);
        if c.inner.search_half_with(&mut c.cache, &input).is_some() {
            1
        } else {
            0
        }
    })
}

/// Find the first match at or after `start_offset`. On match, writes byte
/// offsets into `*out_start`/`*out_end` and returns 1. Returns 0 if no match,
/// -1 on error or panic.
///
/// # Safety
/// `clone`, `hay`, `out_start`, `out_end` must all be valid per the pattern
/// above. `start_offset > hay_len` yields no match (returns 0) rather than an
/// error — matches the regex-automata `Input::span` semantics.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_find(
    clone: *mut ZqRegexClone,
    hay: *const u8,
    hay_len: usize,
    start_offset: usize,
    out_start: *mut usize,
    out_end: *mut usize,
) -> i32 {
    guarded(-1i32, || {
        if out_start.is_null() || out_end.is_null() {
            set_last_error("zq_regex_find: NULL output pointer");
            return -1;
        }
        let (c, haystack) = match resolve_clone_and_hay(clone, hay, hay_len, "zq_regex_find") {
            Some(t) => t,
            None => return -1,
        };
        if start_offset > haystack.len() {
            return 0;
        }
        let input = Input::new(haystack).span(start_offset..haystack.len());
        match c.inner.search_with(&mut c.cache, &input) {
            Some(m) => {
                // SAFETY: out pointers non-null (checked above).
                unsafe {
                    *out_start = m.start();
                    *out_end = m.end();
                }
                1
            }
            None => 0,
        }
    })
}

/// Populate `slots` with `{start, end}` byte offsets for each capture group.
/// Unmatched optional groups leave `start == SIZE_MAX`. `slot_count` must equal
/// `zq_regex_capture_count(regex)` — passing fewer silently truncates; passing
/// more leaves the trailing entries filled with the sentinel.
///
/// Returns 1 on match, 0 on no match, -1 on error or panic.
///
/// # Safety
/// `clone`, `hay` per the is_match_clone contract. `slots` must point to
/// `slot_count` writable `ZqMatchSlot`s (or NULL when `slot_count == 0`).
#[no_mangle]
pub unsafe extern "C" fn zq_regex_find_captures(
    clone: *mut ZqRegexClone,
    hay: *const u8,
    hay_len: usize,
    start_offset: usize,
    slots: *mut ZqMatchSlot,
    slot_count: usize,
) -> i32 {
    guarded(-1i32, || {
        if slots.is_null() && slot_count != 0 {
            set_last_error("zq_regex_find_captures: NULL slots with non-zero count");
            return -1;
        }
        let (c, haystack) = match resolve_clone_and_hay(clone, hay, hay_len, "zq_regex_find_captures")
        {
            Some(t) => t,
            None => return -1,
        };
        if start_offset > haystack.len() {
            return 0;
        }
        let input = Input::new(haystack).span(start_offset..haystack.len());

        // regex-automata's search_slots uses flat [Option<NonMaxUsize>; 2*N].
        // We translate between that flat layout and our {start,end} pair
        // layout in a caller-provided array.
        let mut scratch: Vec<Option<NonMaxUsize>> = vec![None; slot_count * 2];
        let pid = c.inner.search_slots_with(&mut c.cache, &input, &mut scratch);
        if pid.is_none() {
            return 0;
        }

        // SAFETY: slots is non-null when slot_count != 0; writes bounded.
        let out = if slot_count == 0 {
            &mut [][..]
        } else {
            unsafe { slice::from_raw_parts_mut(slots, slot_count) }
        };
        for (i, slot) in out.iter_mut().enumerate() {
            let s = scratch[i * 2].map(NonMaxUsize::get);
            let e = scratch[i * 2 + 1].map(NonMaxUsize::get);
            match (s, e) {
                (Some(a), Some(b)) => {
                    slot.start = a;
                    slot.end = b;
                }
                _ => {
                    slot.start = SLOT_UNMATCHED;
                    slot.end = 0;
                }
            }
        }
        1
    })
}

/// Generator step for `scan`. `*cursor` is the byte offset to begin searching
/// from; on success it is advanced to one-past the match (or to match.start+1
/// in the zero-width case, to guarantee forward progress).
///
/// Returns 1 on match (slots populated), 0 when no further matches remain, -1
/// on error or panic.
///
/// # Safety
/// `clone`, `hay`, `slots` per `zq_regex_find_captures`. `cursor` must be
/// non-null and point at an initialized `usize`.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_iter_next(
    clone: *mut ZqRegexClone,
    hay: *const u8,
    hay_len: usize,
    cursor: *mut usize,
    slots: *mut ZqMatchSlot,
    slot_count: usize,
) -> i32 {
    guarded(-1i32, || {
        if cursor.is_null() {
            set_last_error("zq_regex_iter_next: NULL cursor");
            return -1;
        }
        if slots.is_null() && slot_count != 0 {
            set_last_error("zq_regex_iter_next: NULL slots with non-zero count");
            return -1;
        }
        let (c, haystack) = match resolve_clone_and_hay(clone, hay, hay_len, "zq_regex_iter_next") {
            Some(t) => t,
            None => return -1,
        };
        // SAFETY: cursor non-null (checked above).
        let cur = unsafe { &mut *cursor };
        if *cur > haystack.len() {
            return 0;
        }

        let input = Input::new(haystack).span(*cur..haystack.len());
        let mut scratch: Vec<Option<NonMaxUsize>> = vec![None; slot_count.max(1) * 2];
        let pid = c.inner.search_slots_with(&mut c.cache, &input, &mut scratch);
        if pid.is_none() {
            *cur = haystack.len() + 1; // force termination on next call
            return 0;
        }

        // Match span is always group 0 = slots[0..2].
        let match_start = scratch[0].map(NonMaxUsize::get).unwrap_or(*cur);
        let match_end = scratch[1].map(NonMaxUsize::get).unwrap_or(match_start);

        // Advance cursor. On zero-width match, bump by one byte to guarantee
        // forward progress (matches `regex-automata`'s iter::Searcher logic).
        *cur = if match_end > match_start {
            match_end
        } else {
            match_start + 1
        };

        let out = if slot_count == 0 {
            &mut [][..]
        } else {
            // SAFETY: slots non-null when slot_count != 0.
            unsafe { slice::from_raw_parts_mut(slots, slot_count) }
        };
        for (i, slot) in out.iter_mut().enumerate() {
            let s = scratch.get(i * 2).and_then(|o| o.map(NonMaxUsize::get));
            let e = scratch.get(i * 2 + 1).and_then(|o| o.map(NonMaxUsize::get));
            match (s, e) {
                (Some(a), Some(b)) => {
                    slot.start = a;
                    slot.end = b;
                }
                _ => {
                    slot.start = SLOT_UNMATCHED;
                    slot.end = 0;
                }
            }
        }
        1
    })
}

// ─── prefilter literals (Sparser-style raw-byte prescreen) ───────────────────

/// Borrow the cached literal set for this pattern. Returns NULL when the
/// pattern has no extractable literals (infinite class, e.g. `.+`, `\d+`,
/// single-byte-only alternations), in which case the caller must fall back
/// to the full regex path unconditionally.
///
/// The returned pointer is valid for the lifetime of `handle` and must NOT be
/// freed by the caller. It is internally owned by `ZqRegex`.
///
/// # Safety
/// `handle` must be a live pointer from `zq_regex_compile`.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_required_literals(
    handle: *const ZqRegex,
) -> *const ZqLiterals {
    guarded(ptr::null::<ZqLiterals>(), || {
        if handle.is_null() {
            set_last_error("zq_regex_required_literals: NULL regex handle");
            return ptr::null();
        }
        // SAFETY: caller contract.
        let regex = unsafe { &*handle };
        match &regex.literals {
            Some(l) => l as *const ZqLiterals,
            None => ptr::null(),
        }
    })
}

/// Number of literals in the set.
///
/// # Safety
/// `lits` must be a live pointer returned by `zq_regex_required_literals`.
#[no_mangle]
pub unsafe extern "C" fn zq_literals_count(lits: *const ZqLiterals) -> usize {
    guarded(0usize, || {
        if lits.is_null() {
            return 0;
        }
        // SAFETY: caller contract.
        let l = unsafe { &*lits };
        l.items.len()
    })
}

/// Look up the `idx`th literal. Writes its length to `*out_len` and returns
/// a borrowed byte pointer. Returns NULL on OOB index or NULL inputs.
///
/// # Safety
/// `lits` must be live; `out_len` must be a writable `*mut usize` or NULL when
/// the caller only wants the pointer (the pointer is still not dereferenceable
/// without a length — NULL out_len is always an error).
#[no_mangle]
pub unsafe extern "C" fn zq_literals_at(
    lits: *const ZqLiterals,
    idx: usize,
    out_len: *mut usize,
) -> *const u8 {
    guarded(ptr::null::<u8>(), || {
        if lits.is_null() || out_len.is_null() {
            return ptr::null();
        }
        // SAFETY: caller contract.
        let l = unsafe { &*lits };
        if idx >= l.items.len() {
            return ptr::null();
        }
        let bytes = &l.items[idx];
        // SAFETY: out_len non-null (checked above).
        unsafe {
            *out_len = bytes.len();
        }
        bytes.as_ptr()
    })
}

/// Returns 1 if every literal must appear (AND semantics), 0 if any literal
/// appearing suffices (OR semantics), -1 on NULL input.
///
/// # Safety
/// `lits` must be a live pointer returned by `zq_regex_required_literals`.
#[no_mangle]
pub unsafe extern "C" fn zq_literals_is_exhaustive(lits: *const ZqLiterals) -> i32 {
    guarded(-1i32, || {
        if lits.is_null() {
            return -1;
        }
        // SAFETY: caller contract.
        let l = unsafe { &*lits };
        if l.is_exhaustive { 1 } else { 0 }
    })
}

// ─── last-error channel ───────────────────────────────────────────────────────

/// Copy the last error message into `buf`, null-terminated. Returns the
/// number of bytes written (excluding the terminator), or 0 if no error.
///
/// If the buffer is too small, the message is truncated. A NULL terminator
/// is always written when `buf_len >= 1`.
///
/// # Safety
/// `buf` must point to `buf_len` writable bytes, or be NULL when `buf_len == 0`.
#[no_mangle]
pub unsafe extern "C" fn zq_regex_last_error(buf: *mut c_char, buf_len: usize) -> usize {
    // Deliberately no `guarded` wrapper — this function is the panic-reporting
    // channel. Keep it minimal and panic-free by construction.
    if buf.is_null() || buf_len == 0 {
        return 0;
    }

    LAST_ERROR.with(|cell| {
        let borrow = cell.borrow();
        let msg = match borrow.as_deref() {
            Some(m) => m,
            None => {
                // SAFETY: buf_len >= 1 checked above.
                unsafe { *buf = 0 };
                return 0;
            }
        };

        let bytes = msg.as_bytes();
        let max_copy = buf_len.saturating_sub(1);
        let copy_len = bytes.len().min(max_copy);

        // SAFETY: buf is valid for buf_len bytes; copy_len <= buf_len - 1.
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, copy_len);
            *buf.add(copy_len) = 0;
        }
        copy_len
    })
}

// ─── panic-survival test hook ─────────────────────────────────────────────────

/// Deliberately panic inside the shim. Returns -1 unconditionally: if
/// `guarded` works the panic is caught and -1 comes back through that path;
/// if it doesn't, the process aborts (which the test treats as failure).
///
/// This is the integration test for the FFI panic-safety contract. It is
/// `#[doc(hidden)]` and exists solely so the Zig test suite can assert that
/// the process survives a Rust panic.
#[no_mangle]
#[doc(hidden)]
pub extern "C" fn zq_regex__test_panic() -> i32 {
    guarded(-1i32, || {
        panic!("zq_regex__test_panic: deliberate panic for FFI safety test");
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_panic_is_caught() {
        // Direct Rust-side test — Zig tests cover the FFI path.
        let rc = zq_regex__test_panic();
        assert_eq!(rc, -1);
    }

    #[test]
    fn test_clone_search() {
        unsafe {
            let pat = b"foo(?<n>\\d+)";
            let re = zq_regex_compile(pat.as_ptr(), pat.len());
            assert!(!re.is_null());

            let cnt = zq_regex_capture_count(re);
            assert_eq!(cnt, 2); // implicit group 0 + 1 named

            let idx = zq_regex_group_index_by_name(re, b"n".as_ptr(), 1);
            assert_eq!(idx, 1);

            let clone = zq_regex_clone(re);
            assert!(!clone.is_null());

            let hay = b"foo42";
            let rc = zq_regex_is_match_clone(clone, hay.as_ptr(), hay.len());
            assert_eq!(rc, 1);

            let mut slots = [ZqMatchSlot { start: 0, end: 0 }; 2];
            let rc = zq_regex_find_captures(
                clone,
                hay.as_ptr(),
                hay.len(),
                0,
                slots.as_mut_ptr(),
                slots.len(),
            );
            assert_eq!(rc, 1);
            assert_eq!(slots[0].start, 0);
            assert_eq!(slots[0].end, 5);
            assert_eq!(slots[1].start, 3);
            assert_eq!(slots[1].end, 5);

            zq_regex_clone_free(clone);
            zq_regex_free(re);
        }
    }

    #[test]
    fn test_literals_exhaustive_literal_pattern() {
        unsafe {
            let pat = b"hello world";
            let re = zq_regex_compile(pat.as_ptr(), pat.len());
            let lits = zq_regex_required_literals(re);
            assert!(!lits.is_null());
            assert_eq!(zq_literals_is_exhaustive(lits), 1);
            assert_eq!(zq_literals_count(lits), 1);
            let mut len: usize = 0;
            let p = zq_literals_at(lits, 0, &mut len);
            let slice = std::slice::from_raw_parts(p, len);
            assert_eq!(slice, b"hello world");
            zq_regex_free(re);
        }
    }

    #[test]
    fn test_literals_alternation() {
        unsafe {
            let pat = b"foo|bar|baz";
            let re = zq_regex_compile(pat.as_ptr(), pat.len());
            let lits = zq_regex_required_literals(re);
            assert!(!lits.is_null());
            // Alternation of literals is extracted exactly; OR-semantics means
            // ANY literal appearing is sufficient.
            assert_eq!(zq_literals_count(lits), 3);
            zq_regex_free(re);
        }
    }

    #[test]
    fn test_literals_unbounded_pattern() {
        unsafe {
            let pat = b".+";
            let re = zq_regex_compile(pat.as_ptr(), pat.len());
            let lits = zq_regex_required_literals(re);
            // `.+` has no extractable literals — prefilter must be disabled.
            assert!(lits.is_null());
            zq_regex_free(re);
        }
    }

    #[test]
    fn test_literals_digit_class() {
        unsafe {
            let pat = b"\\d+";
            let re = zq_regex_compile(pat.as_ptr(), pat.len());
            let lits = zq_regex_required_literals(re);
            // Digit class expands to 10 single-byte literals which we filter
            // out (< MIN_LITERAL_LEN) — prefilter disabled.
            assert!(lits.is_null());
            zq_regex_free(re);
        }
    }

    #[test]
    fn test_iter_next_basic() {
        unsafe {
            let pat = b"\\d+";
            let re = zq_regex_compile(pat.as_ptr(), pat.len());
            let clone = zq_regex_clone(re);
            let hay = b"a1 b22 c333";

            let mut cursor: usize = 0;
            let mut slot = [ZqMatchSlot { start: 0, end: 0 }];

            let r1 = zq_regex_iter_next(clone, hay.as_ptr(), hay.len(), &mut cursor, slot.as_mut_ptr(), 1);
            assert_eq!(r1, 1);
            assert_eq!((slot[0].start, slot[0].end), (1, 2));

            let r2 = zq_regex_iter_next(clone, hay.as_ptr(), hay.len(), &mut cursor, slot.as_mut_ptr(), 1);
            assert_eq!(r2, 1);
            assert_eq!((slot[0].start, slot[0].end), (4, 6));

            let r3 = zq_regex_iter_next(clone, hay.as_ptr(), hay.len(), &mut cursor, slot.as_mut_ptr(), 1);
            assert_eq!(r3, 1);
            assert_eq!((slot[0].start, slot[0].end), (8, 11));

            let r4 = zq_regex_iter_next(clone, hay.as_ptr(), hay.len(), &mut cursor, slot.as_mut_ptr(), 1);
            assert_eq!(r4, 0);

            zq_regex_clone_free(clone);
            zq_regex_free(re);
        }
    }
}
