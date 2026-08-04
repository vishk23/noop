#ifndef WHOOPSTORE_CSHIMS_H
#define WHOOPSTORE_CSHIMS_H

// Fixed-arity wrappers for SQLite C APIs Swift cannot call.
//
// `sqlite3_db_config` is C-variadic, and the SDK marks C-variadic functions unavailable to Swift
// ("Variadic function is unavailable"), so the one verb this package needs —
// SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, which takes an (int, int*) tail — is wrapped here. Calling a
// variadic through a fixed-arity function pointer instead (dlsym + cast) is not an option: on
// arm64 Darwin variadic arguments travel on the stack while fixed arguments travel in registers,
// so the cast is an ABI mismatch, not a shortcut.
//
// The handle parameter is `void *` so this header needs no `sqlite3` typedef that could collide
// with the one Swift already imports; callers pass the raw pointer GRDB exposes as
// `Database.sqliteConnection`.

/// Disable SQLite's close-time checkpoint on the connection `db`
/// (`sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, outDisabled)`).
/// On success writes 1 into `outDisabled`. Returns the sqlite3_db_config result code.
int whoopstore_disable_checkpoint_on_close(void *db, int *outDisabled);

/// Read back whether close-time checkpointing is disabled on `db`, without changing it
/// (the verb's -1 query form). Writes 0 or 1 into `outDisabled`. Used by tests.
int whoopstore_checkpoint_on_close_disabled(void *db, int *outDisabled);

#endif
