package io.github.haige120.cloudreader.sync

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop

/** Omits the initial snapshot, then emits only actual changes from a long-lived preference flow. */
internal fun <T> Flow<T>.afterInitialDistinct(): Flow<T> = distinctUntilChanged().drop(1)
