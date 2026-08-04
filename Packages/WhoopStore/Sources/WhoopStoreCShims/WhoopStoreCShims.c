#include "WhoopStoreCShims.h"
#include <sqlite3.h>

int whoopstore_disable_checkpoint_on_close(void *db, int *outDisabled) {
    return sqlite3_db_config((sqlite3 *)db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, outDisabled);
}

int whoopstore_checkpoint_on_close_disabled(void *db, int *outDisabled) {
    return sqlite3_db_config((sqlite3 *)db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, -1, outDisabled);
}
